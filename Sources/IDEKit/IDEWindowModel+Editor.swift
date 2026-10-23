// @author ixxxxoooo
// IDE 窗口的编辑器标签操作:打开/关闭/改指文件标签,基于 `DockLayout`(拆分、预览与固定标签规则与 Agent 窗口一致)。

import Foundation
import WorkbenchKit

public extension IDEWindowModel {
    /// 当前聚焦组里激活的文件路径。
    var activeFilePath: String? {
        guard case .file(let path)? = editor.focusedGroup?.active?.kind else { return nil }
        return path
    }

    /// 窗口内所有打开的文件路径(去重,保持从左到右、从上到下的顺序)。
    var openFilePaths: [String] {
        var seen = Set<String>()
        return editor.allTabs.compactMap { tab -> String? in
            guard case .file(let path) = tab.kind, seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// 打开文件标签:已打开则聚焦;否则按预览/固定规则新建。
    /// - Parameters:
    ///   - path: 文件绝对路径(空串忽略)
    ///   - line: 要定位的行(1 起始)
    ///   - preview: 是否以预览方式打开(单击预览,双击固定)
    ///   - beside: 是否在聚焦组右侧的新分屏中打开
    /// - Returns: 标签标识;路径为空返回 nil
    @discardableResult
    func openFile(_ path: String, line: Int? = nil, preview: Bool = true, beside: Bool = false) -> UUID? {
        guard !path.isEmpty else { return nil }
        let title = (path as NSString).lastPathComponent
        var layout = editor
        let id: UUID
        if beside {
            id = layout.openBeside(.file(path: path), title: title, of: layout.focusedGroupID, preview: preview, keepFocus: false)
            // 已存在的标签再次 open 只会聚焦并更新行号
            if let line { layout.open(.file(path: path), title: title, preview: preview, line: line) }
        } else {
            id = layout.open(.file(path: path), title: title, preview: preview, line: line)
        }
        editor = layout
        return id
    }

    /// 打开「Composer 多文件审阅」标签(本轮 Agent 改动汇总;已打开则聚焦)。
    /// - Parameters:
    ///   - projectID: Agent 面板所属项目标识
    ///   - title: 标签标题
    /// - Returns: 标签标识;项目为空返回 nil
    @discardableResult
    func openChanges(projectID: String, title: String) -> UUID? {
        guard !projectID.isEmpty else { return nil }
        var layout = editor
        let id = layout.open(.changes(projectID: projectID), title: title, preview: false)
        editor = layout
        return id
    }

    /// 打开某文件的差异标签(已打开则聚焦)。
    /// - Parameter path: 文件绝对路径(空串忽略)
    /// - Returns: 标签标识
    @discardableResult
    func openDiff(_ path: String) -> UUID? {
        guard !path.isEmpty else { return nil }
        var layout = editor
        let id = layout.open(.diff(path: path), title: (path as NSString).lastPathComponent + " ⇄", preview: true)
        editor = layout
        return id
    }

    /// 打开某文件(或整个仓库)的 Git 历史标签。
    /// - Parameters:
    ///   - project: 项目根目录
    ///   - path: 仅看该文件的历史;nil 为整个仓库
    @discardableResult
    func openHistory(project: String, path: String?) -> UUID? {
        guard !project.isEmpty else { return nil }
        var layout = editor
        let title = path.map { String(localized: "历史") + " · " + ($0 as NSString).lastPathComponent } ?? String(localized: "Git 历史")
        let id = layout.open(.history(projectID: project, path: path), title: title, preview: true)
        editor = layout
        return id
    }

    /// 打开某文件的逐行追溯(blame)标签。
    /// - Parameter path: 文件绝对路径
    @discardableResult
    func openBlame(_ path: String) -> UUID? {
        guard !path.isEmpty else { return nil }
        var layout = editor
        let id = layout.open(.blame(path: path), title: "Blame · " + (path as NSString).lastPathComponent, preview: true)
        editor = layout
        return id
    }

    /// 打开子 Agent 的只读完整会话标签(已打开则聚焦)。
    /// - Parameters:
    ///   - project: 项目 ID
    ///   - toolCallID: 派生子 Agent 的工具调用 ID
    ///   - title: 标签标题
    /// - Returns: 标签标识;入参为空返回 nil
    @discardableResult
    func openSubagent(project: String, toolCallID: String, title: String) -> UUID? {
        guard !project.isEmpty, !toolCallID.isEmpty else { return nil }
        var layout = editor
        let id = layout.open(.subagent(projectID: project, toolCallID: toolCallID), title: title, preview: false)
        editor = layout
        return id
    }

    /// 关闭某标签。
    /// - Parameter tabID: 标签标识
    func closeTab(_ tabID: UUID) {
        var layout = editor
        layout.close(tabID)
        editor = layout
    }

    /// 关闭路径位于某文件或目录之下的所有文件标签(文件被删除/移走时)。
    /// - Parameter path: 文件或目录路径
    func closeFileTabs(under path: String) {
        var layout = editor
        layout.closeTabs { tab in
            guard case .file(let file) = tab.kind else { return false }
            return file == path || file.hasPrefix(path + "/")
        }
        editor = layout
        forgetNavigation(under: path)
    }

    /// 把指向 `from`(或其子路径)的文件标签改指 `to`(重命名/移动后)。
    /// - Parameters:
    ///   - from: 旧路径
    ///   - to: 新路径
    func retargetFileTabs(from: String, to: String) {
        var layout = editor
        for tab in layout.allTabs {
            guard case .file(let file) = tab.kind, file == from || file.hasPrefix(from + "/") else { continue }
            let newPath = to + file.dropFirst(from.count)
            layout.retarget(tab.id, kind: .file(path: String(newPath)), title: (newPath as NSString).lastPathComponent)
        }
        forgetNavigation(under: from)
        editor = layout
    }

    /// 同步某文件的脏标记到所有指向它的标签。
    /// - Parameters:
    ///   - path: 文件路径
    ///   - dirty: 是否有未保存修改
    func setDirty(_ dirty: Bool, forFile path: String) {
        var layout = editor
        var changed = false
        for tab in layout.allTabs where tab.kind == .file(path: path) && tab.isDirty != dirty {
            layout.setDirty(dirty, for: tab.id)
            changed = true
        }
        if changed { editor = layout }
    }
}
