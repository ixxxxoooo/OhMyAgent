// @author ixxxxoooo
// 应用级动作桥:把 SwiftUI 的 openWindow / openSettings 暴露给 AppKit 代码(托盘、通知点击),
// 并承载「打开某个会话」的跨窗口请求。

import ChatKit
import OMLog
import SwiftUI

/// 打开会话请求。
struct SessionOpenRequest: Equatable {
    var workspacePath: String
    var sessionId: String?
    var title: String?
    var nonce = UUID()
}

@MainActor
@Observable
final class AppActions {
    static let shared = AppActions()

    /// 待处理的会话打开请求(由对应工作区窗口消费)
    var sessionRequest: SessionOpenRequest?

    /// 主窗口(由工作台视图登记;窗口关闭后系统会释放它)
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var openWindowAction: OpenWindowAction?

    /// 由窗口视图捕获环境动作。
    func capture(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// 把目录加入工作台(已存在则选中)并前置主窗口。
    func openWorkspace(_ url: URL) {
        Log.app.info("打开项目", ["path": url.path])
        AppEnvironment.shared.workbench.openProject(url)
        showMainWindow()
    }

    /// 重新启动应用:先拉起一个等待当前进程退出后再打开应用包的后台 shell,然后正常退出
    /// (退出流程会清理 Agent 子进程与持久化状态)。非 `.app` 包形态(如 `swift run`)下无法重启,仅记录日志。
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            Log.ui.warning("非应用包形态,无法重启", ["path": bundleURL.lastPathComponent])
            return
        }
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        do {
            try process.run()
            Log.ui.info("应用重启已安排")
            NSApp.terminate(nil)
        } catch {
            Log.ui.error("拉起重启脚本失败", ["error": "\(error)"])
        }
    }

    /// 打开设置整页(并入主窗口,可深链到某页)。
    func openSettings(page: SettingsPage? = nil) {
        if let page { SettingsRouter.shared.go(page) }
        AppEnvironment.shared.workbench.openSettings()
        showMainWindow()
    }

    /// 回到对话并把文本追加到当前会话的输入框(设置页里的「在对话中使用」)。
    /// - Parameter text: 要插入的文本(如 `/review ` 或 `@agent-explorer `)
    func insertIntoComposer(_ text: String) {
        let workbench = AppEnvironment.shared.workbench
        workbench.closeSettings()
        guard let id = workbench.selectedProjectID, let model = workbench.sessions[id] else { return }
        let separator = model.draft.isEmpty || model.draft.hasSuffix(" ") || model.draft.hasSuffix("\n") ? "" : " "
        model.draft += separator + text
        showMainWindow()
    }

    /// 把所有文件标签的「未保存」标记与文档状态对齐(保存/重新载入后调用)。
    func refreshDirtyFlags() {
        let workbench = AppEnvironment.shared.workbench
        for tab in workbench.dock.allTabs {
            if case .file(let path) = tab.kind {
                workbench.dock.setDirty(FileDocumentStore.shared.documents[path]?.isDirty ?? false, for: tab.id)
            }
        }
    }

    /// 保存当前聚焦标签对应的文件。
    func saveActiveFile() {
        let workbench = AppEnvironment.shared.workbench
        guard case .file(let path)? = workbench.dock.focusedGroup?.active?.kind else { return }
        Task { _ = await FileDocumentStore.shared.save(path); refreshDirtyFlags() }
    }

    /// 保存所有未保存的文件。
    func saveAllFiles() {
        Task { _ = await FileDocumentStore.shared.saveAll(); refreshDirtyFlags() }
    }

    /// 是否存在可保存的当前文件(供菜单启用状态)。
    var canSaveActiveFile: Bool {
        guard case .file(let path)? = AppEnvironment.shared.workbench.dock.focusedGroup?.active?.kind else { return false }
        return FileDocumentStore.shared.documents[path]?.isDirty ?? false
    }

    /// ⌘W:关闭聚焦组的当前标签;固定标签不关闭;没有任何标签时才关闭窗口。
    func closeActiveTabOrWindow() {
        let workbench = AppEnvironment.shared.workbench
        if let tab = workbench.dock.focusedGroup?.active {
            if !tab.isPinned { requestCloseTab(tab.id) }
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// 请求关闭标签:文件有未保存修改时询问「保存 / 不保存 / 取消」。
    func requestCloseTab(_ id: UUID) {
        let workbench = AppEnvironment.shared.workbench
        guard let tab = workbench.dock.tab(id) else { return }
        guard case .file(let path) = tab.kind, let doc = FileDocumentStore.shared.documents[path], doc.isDirty else {
            workbench.closeTab(id)
            return
        }
        let choice = OMDialog.show(
            title: String(localized: "要保存对 \((path as NSString).lastPathComponent) 的修改吗?"),
            message: String(localized: "如果不保存,你的修改将会丢失。"),
            buttons: [.cancel(), .destructive(String(localized: "不保存")), .primary(String(localized: "保存"))]
        ).index
        switch choice {
        case 2:
            Task {
                if await FileDocumentStore.shared.save(path) { FileDocumentStore.shared.discard(path); workbench.closeTab(id) }
            }
        case 1:
            FileDocumentStore.shared.discard(path)
            workbench.closeTab(id)
        default: break
        }
    }

    /// 依次关闭一批标签;含未保存文件的标签会逐个询问(取消只影响那一个)。
    /// - Parameter ids: 标签 ID 列表
    func requestCloseTabs(_ ids: [UUID]) {
        for id in ids { requestCloseTab(id) }
    }

    /// 在当前项目目录新建终端标签。
    func openTerminal() {
        let workbench = AppEnvironment.shared.workbench
        let directory = workbench.selectedProjectID ?? NSHomeDirectory()
        let id = UUID().uuidString
        TerminalStore.shared.register(id: id, directory: directory)
        let index = workbench.dock.allTabs.filter { if case .terminal = $0.kind { return true } else { return false } }.count + 1
        workbench.openTerminal(id: id, title: String(localized: "终端") + (index > 1 ? " \(index)" : ""))
        showMainWindow()
    }

    /// 打开预览标签(如放大的 Mermaid 图)。
    func openPreview(id: String, title: String) {
        AppEnvironment.shared.workbench.openPreview(id: id, title: title)
        showMainWindow()
    }

    /// 打开某个会话(点击通知或托盘菜单):选中项目并请求切换到会话。
    func openSession(workspacePath: String, sessionId: String?, title: String?, uid: String? = nil) {
        Log.app.info("请求打开会话", ["workspace": workspacePath, "session": sessionId ?? "-"])
        if let uid { AttentionCenter.shared.markRead(uid) }
        guard AppEnvironment.shared.workbench.openProject(URL(fileURLWithPath: workspacePath)) != nil else { return }
        sessionRequest = SessionOpenRequest(workspacePath: workspacePath, sessionId: sessionId, title: title)
        showMainWindow()
    }

    /// 在当前项目下开始新对话并前置主窗口。
    func newConversation() {
        AppEnvironment.shared.workbench.newConversationInContext()
        showMainWindow()
    }

    /// 前置主窗口;窗口已被关闭时重新打开。
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }
}
