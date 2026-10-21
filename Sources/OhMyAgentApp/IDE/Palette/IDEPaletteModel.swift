// @author ixxxxoooo
// IDE 命令面板/快速打开的状态与命令执行:⌘P 文件、⇧⌘P 命令(`>`)、`:` 转到行,共用一个输入框。
// 文件索引按窗口根目录独立(IDE 窗口可以打开不同于 Agent 窗口的目录)。

import AppKit
import EditorKit
import IDEKit
import Observation
import OMLog
import WorkbenchKit

/// 面板里的一行结果。
enum IDEPaletteItem: Identifiable {
    case file(FuzzyMatch)
    case command(IDECommandMatch)
    case line(Int?, Int?)

    var id: String {
        switch self {
        case .file(let match): "f:" + match.path
        case .command(let match): "c:" + match.command.id
        case .line(let line, let column): "l:\(line ?? 0):\(column ?? 0)"
        }
    }
}

@MainActor
@Observable
final class IDEPaletteModel {
    /// 是否显示
    var isPresented = false
    /// 输入框文本(含前缀)
    var text = "" { didSet { if text != oldValue { highlighted = 0 } } }
    /// 高亮行
    var highlighted = 0
    /// 工作区相对路径索引
    private(set) var files: [String] = []
    /// 命令注册表(含最近使用)
    private(set) var registry = IDECommandRegistry()
    @ObservationIgnored private var indexRoot: String?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    /// 解析后的查询。
    var query: IDEPaletteQuery { IDEPaletteQuery.parse(text) }

    /// 打开面板。
    /// - Parameters:
    ///   - prefix: 初始前缀(`""` 文件、`">"` 命令、`":"` 转到行)
    ///   - root: 工作区根目录(用于文件索引)
    func present(prefix: String, root: String?) {
        text = prefix
        highlighted = 0
        isPresented = true
        refreshIndex(root: root)
    }

    /// 关闭面板。
    func dismiss() { isPresented = false }

    /// 重建文件索引(根目录变化或每次打开时,后台扫描;旧结果先用着)。
    private func refreshIndex(root: String?) {
        guard let root else { files = []; indexRoot = nil; return }
        if indexRoot != root { files = [] }
        indexRoot = root
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let started = ContinuousClock.now
            let list = await Task.detached(priority: .userInitiated) { WorkspaceFiles.index(root: root) }.value
            guard !Task.isCancelled, let self, self.indexRoot == root else { return }
            self.files = list
            Log.editor.info("IDE 快速打开索引", ["root": root, "files": "\(list.count)",
                                              "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
        }
    }

    /// 当前查询的结果行。
    /// - Parameters:
    ///   - context: 命令上下文
    ///   - recents: 已打开文件的相对路径(最近在前)
    func items(context: IDECommandContext, recents: [String]) -> [IDEPaletteItem] {
        switch query {
        case .files(let text):
            return IDEQuickOpen.rank(query: text, files: files, recents: recents).map(IDEPaletteItem.file)
        case .commands(let text):
            return registry.search(query: text, context: context).map(IDEPaletteItem.command)
        case .line(let line, let column):
            return [.line(line, column)]
        }
    }

    /// 记录命令使用。
    /// - Parameter id: 命令标识
    func recordUse(_ id: String) { registry.recordUse(id) }

    /// 高亮上下移动(越界钳制)。
    /// - Parameters:
    ///   - delta: 步长
    ///   - count: 结果总数
    func move(_ delta: Int, count: Int) {
        guard count > 0 else { highlighted = 0; return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }
}

// MARK: - 工作区侧:上下文与命令执行

extension IDEWorkspace {
    /// 命令可用条件所需的上下文快照。
    var commandContext: IDECommandContext {
        IDECommandContext(hasFolder: root != nil, hasActiveFile: model.activeFilePath != nil, hasDirty: !dirtyPaths.isEmpty)
    }

    /// 已打开文件的相对路径(最近在前,以活动文件为首)。
    var openRelativePaths: [String] {
        guard let root else { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var paths = model.openFilePaths
        if let active = model.activeFilePath, let index = paths.firstIndex(of: active) { paths.move(fromOffsets: IndexSet(integer: index), toOffset: 0) }
        return paths.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
    }

    /// 打开命令面板。
    /// - Parameter prefix: 初始前缀
    func openPalette(_ prefix: String) {
        palette.present(prefix: prefix, root: root)
    }

    /// 选中面板里的一行并执行。
    /// - Parameter item: 结果行
    func choose(_ item: IDEPaletteItem) {
        palette.dismiss()
        switch item {
        case .file(let match):
            guard let root else { return }
            open((root as NSString).appendingPathComponent(match.path), preview: false)
        case .command(let match):
            palette.recordUse(match.command.id)
            perform(match.command.id)
        case .line(let line, let column):
            guard let line else { return }
            Task { @MainActor in
                // 等面板收起、焦点回到编辑器后再定位
                try? await Task.sleep(for: .milliseconds(60))
                CodeEditorView.activeEditor()?.goToLine(line, column: column ?? 1)
            }
        }
    }

    /// 执行一条命令。
    /// - Parameter id: 命令标识(见 `IDECommandRegistry.builtin`)
    func perform(_ id: String) {
        Log.ui.info("IDE 命令", ["id": id])
        switch id {
        case "file.save": saveActive()
        case "file.saveAll": saveAll()
        case "file.closeTab": _ = closeActiveTab()
        case "file.reopenTab": reopenClosed()
        case "file.newFile": if let root { create(in: root, isDirectory: false) }
        case "file.newFolder": if let root { create(in: root, isDirectory: true) }
        case "file.openFolder":
            if root == nil { IDEWindowManager.shared.chooseFolder(for: model) } else { IDEWindowManager.shared.openFolderInNewWindow() }
        case "go.quickOpen": openPalette("")
        case "go.line": openPalette(":")
        case "go.nextTab": cycleTab(by: 1)
        case "go.previousTab": cycleTab(by: -1)
        case "go.revealActiveFile":
            if let path = model.activeFilePath { model.selectSidebar(.explorer); reveal(path) }
        case "edit.toggleComment": CodeEditorView.activeEditor()?.perform(.toggleComment)
        case "edit.moveLineUp": CodeEditorView.activeEditor()?.perform(.moveLineUp)
        case "edit.moveLineDown": CodeEditorView.activeEditor()?.perform(.moveLineDown)
        case "edit.addNextOccurrence": CodeEditorView.activeEditor()?.perform(.addNextOccurrence)
        case "view.toggleSidebar": model.toggleSidebar()
        case "view.togglePanel": model.togglePanel()
        case "view.toggleAgentPane": model.toggleAgentPane()
        case "view.explorer": model.sidebarVisible = true; model.selectSidebar(.explorer)
        case "view.search": model.sidebarVisible = true; model.selectSidebar(.search); search.requestFocus()
        case "view.scm": model.sidebarVisible = true; model.selectSidebar(.scm)
        case "view.problems": model.showPanel(.problems)
        case "terminal.new": newTerminal()
        case "agent.newChat": model.agentPaneVisible = true; newAgentConversation()
        case "agent.addFile": addActiveFileToChat()
        case "agent.openWindow": IDEWindowManager.shared.switchToAgent()
        case "window.new": IDEWindowManager.shared.newEmptyWindow()
        case "scm.refresh":
            if let root { let git = GitStore.shared.model(for: root); Task { await git.refresh() } }
        default:
            Log.ui.warning("未知的 IDE 命令", ["id": id])
        }
    }
}
