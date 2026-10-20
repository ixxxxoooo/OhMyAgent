// @author ixxxxoooo
// 资源管理器文件操作撤销:持有撤销栈,拦截 ⌘Z(指针在资源管理器内且没有文本框在编辑时)回退最近一次文件操作。

import AppKit
import OMLog
import WorkbenchKit

/// 资源管理器撤销中心(主线程单例)。
@MainActor
final class ExplorerUndoCenter {
    static let shared = ExplorerUndoCenter()

    private var history = FileOpHistory()
    private weak var workbench: WorkbenchModel?
    private var monitor: Any?
    /// 指针是否在资源管理器内(由视图 `onHover` 维护)
    var pointerInside = false

    /// 记录一次已完成的文件操作。
    /// - Parameters:
    ///   - group: 操作组
    ///   - workbench: 工作台(撤销后用于刷新标签与索引)
    func record(_ group: FileOpGroup, workbench: WorkbenchModel) {
        self.workbench = workbench
        history.push(group)
    }

    /// 安装 ⌘Z 监视器(幂等)。
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
    }

    /// 处理按键:仅 ⌘Z、指针在资源管理器内、无文本编辑、栈非空时接管。
    private func handle(_ event: NSEvent) -> Bool {
        guard pointerInside, history.canUndo,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers == "z",
              !(event.window?.firstResponder is NSText) else { return false }
        undo()
        return true
    }

    /// 回退最近一次文件操作并刷新界面。
    func undo() {
        guard let group = history.popLast() else { return }
        let workbench = self.workbench
        Task {
            let failures = await Task.detached { FileOpReverter.revert(group) }.value
            if let workbench {
                for op in group.ops {
                    switch op {
                    case .move(let from, let to):
                        // 已打开的标签随文件回到原路径
                        workbench.retargetFilesInAllDocks(from: to, to: from)
                    case .created(let path):
                        workbench.closeTabsInAllDocks { tab in
                            if case .file(let p) = tab.kind { return p == path || p.hasPrefix(path + "/") }
                            return false
                        }
                    case .trashed: break
                    }
                }
                WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
            }
            ExplorerModel.shared.bump()
            Log.editor.info("资源管理器撤销", ["title": group.title, "failed": "\(failures.count)"])
            if !failures.isEmpty {
                OMDialog.alert(title: String(localized: "撤销未完全成功"), message: failures.joined(separator: "\n"), isError: true)
            }
        }
    }
}
