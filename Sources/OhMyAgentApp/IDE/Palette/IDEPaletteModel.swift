// @author ixxxxoooo
// IDE 命令面板/快速打开的状态与命令执行:⌘P 文件、⇧⌘P 命令(`>`)、`:` 转到行,共用一个输入框。
// 文件索引按窗口根目录独立(IDE 窗口可以打开不同于 Agent 窗口的目录)。

import AppKit
import DesignSystem
import EditorKit
import IDEKit
import Observation
import OMLog
import WorkbenchKit

/// 面板里的一行结果。
/// 自定义列表(引用、符号)里的一个位置。
struct IDEPaletteLocation: Identifiable, Equatable {
    let id: String
    /// 主标题(符号名、命中行文本)
    let title: String
    /// 副标题(文件相对路径与行号)
    let detail: String
    /// Lucide 图标名
    let icon: String
    /// 绝对路径
    let path: String
    /// 行号(1 起始)
    let line: Int
    /// 缩进层级(符号层级)
    var depth = 0
    /// 非空时选中即执行 `IDEWorkspace.paletteActions` 里登记的动作(快速修复),而不是跳转文件
    var actionID: String?
    /// 非空时这一行是颜色主题:键盘移动高亮即实时预览,回车提交
    var themeID: String?
}

enum IDEPaletteItem: Identifiable {
    case file(FuzzyMatch)
    case command(IDECommandMatch)
    case line(Int?, Int?)
    case location(IDEPaletteLocation)

    var id: String {
        switch self {
        case .file(let match): "f:" + match.path
        case .command(let match): "c:" + match.command.id
        case .line(let line, let column): "l:\(line ?? 0):\(column ?? 0)"
        case .location(let location): "p:" + location.id
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
    /// 每次打开面板递增:视图据此重新把焦点交给输入框(焦点可能还在终端或编辑器上)
    private(set) var focusToken = 0
    /// 工作区相对路径索引
    private(set) var files: [String] = [] { didSet { filesRevision &+= 1 } }
    /// 文件索引的修订号:索引变化后文件结果的缓存失效
    @ObservationIgnored private var filesRevision = 0
    /// 文件结果缓存的键:输入、索引修订号与已打开文件列表都没变时复用上次排序(悬停改高亮行也会重算 body)
    private struct RankKey: Equatable {
        let text: String
        let filesRevision: Int
        let recents: [String]
    }
    @ObservationIgnored private var rankMemo: (key: RankKey, items: [IDEPaletteItem])?
    /// 正在后台计算的键(避免同一输入重复排队)
    @ObservationIgnored private var pendingKey: RankKey?
    @ObservationIgnored private var rankTask: Task<Void, Never>?
    /// 后台排序结果到达时加一:视图读取它,结果落地后自动重算
    private(set) var rankRevision = 0
    /// 超过该文件数时排序放到后台(输入期间先沿用上一次结果,不阻塞主线程)
    static let asyncRankThreshold = 3_000
    /// 命令注册表(含最近使用)
    private(set) var registry = IDECommandRegistry()
    @ObservationIgnored private var indexRoot: String?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    /// 解析后的查询。
    var query: IDEPaletteQuery { IDEPaletteQuery.parse(text) }

    /// 自定义列表(引用、符号):非 nil 时面板显示它,输入框用于过滤
    private(set) var customItems: [IDEPaletteLocation]?
    /// 自定义列表的输入框占位文案
    private(set) var customPlaceholder = ""

    /// 以自定义列表打开面板(查找引用、转到符号)。
    /// - Parameters:
    ///   - items: 列表
    ///   - placeholder: 输入框占位文案
    func present(custom items: [IDEPaletteLocation], placeholder: String) {
        customItems = items
        customPlaceholder = placeholder
        text = ""
        highlighted = 0
        focusToken += 1
        isPresented = true
    }

    /// 打开面板。
    /// - Parameters:
    ///   - prefix: 初始前缀(`""` 文件、`">"` 命令、`":"` 转到行)
    ///   - root: 工作区根目录(用于文件索引)
    func present(prefix: String, root: String?) {
        customItems = nil
        text = prefix
        highlighted = 0
        focusToken += 1
        isPresented = true
        refreshIndex(root: root)
    }

    /// 颜色主题选择器打开时的原主题:非 nil 表示正在预览,取消(Esc/点遮罩)时还原
    @ObservationIgnored private var themeRevertID: String?

    /// 以主题列表打开面板(参考 VS Code「颜色主题」):↑↓ 实时预览,↩ 应用,Esc 还原。
    func presentThemes() {
        let current = AppearanceModel.shared.themeID
        let items = ThemePackage.all.map { package in
            IDEPaletteLocation(id: "theme:" + package.id, title: package.name, detail: package.tone.displayName,
                               icon: package.id == current ? "check" : "paintbrush", path: "", line: 0, themeID: package.id)
        }
        present(custom: items, placeholder: String(localized: "选择颜色主题(↑↓ 预览,↩ 应用,Esc 取消)"))
        themeRevertID = current
        highlighted = items.firstIndex { $0.themeID == current } ?? 0
        themeKeys.install { [weak self] command in self?.handleThemeKey(command) ?? false }
    }

    /// 预览高亮的主题行(非主题行或不在主题选择器里时忽略)。
    /// - Parameter item: 当前高亮的结果行
    func previewTheme(_ item: IDEPaletteItem?) {
        guard themeRevertID != nil, case .location(let location)? = item, let id = location.themeID,
              AppearanceModel.shared.themeID != id else { return }
        AppearanceModel.shared.themeID = id
    }

    /// 提交主题:之后关闭面板不再还原。
    /// - Parameter id: 主题 id
    func commitTheme(_ id: String) {
        themeRevertID = nil
        AppearanceModel.shared.themeID = id
    }

    /// 关闭面板(主题预览中则还原原主题)。
    func dismiss() {
        if let id = themeRevertID {
            themeRevertID = nil
            AppearanceModel.shared.themeID = id
        }
        themeKeys.remove()
        isPresented = false
    }

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
        if customItems != nil { return filteredCustom.map(IDEPaletteItem.location) }
        switch query {
        case .files(let text):
            return rankedFiles(text: text, recents: recents)
        case .commands(let text):
            return registry.search(query: text, context: context).map(IDEPaletteItem.command)
        case .line(let line, let column):
            return [.line(line, column)]
        }
    }

    /// 文件结果:命中缓存直接返回;文件数不大时同步排序;文件很多时在后台排序,期间沿用上一次结果。
    private func rankedFiles(text: String, recents: [String]) -> [IDEPaletteItem] {
        _ = rankRevision   // 建立观察:后台结果落地后视图重算
        let key = RankKey(text: text, filesRevision: filesRevision, recents: recents)
        if let memo = rankMemo, memo.key == key { return memo.items }
        if files.count <= Self.asyncRankThreshold || rankMemo == nil {
            let items = IDEQuickOpen.rank(query: text, files: files, recents: recents).map(IDEPaletteItem.file)
            rankMemo = (key, items)
            return items
        }
        if pendingKey != key {
            pendingKey = key
            let snapshot = files
            rankTask?.cancel()
            rankTask = Task { [weak self] in
                let ranked = await Task.detached(priority: .userInitiated) {
                    IDEQuickOpen.rank(query: text, files: snapshot, recents: recents)
                }.value
                guard !Task.isCancelled, let self, self.pendingKey == key else { return }
                self.rankMemo = (key, ranked.map(IDEPaletteItem.file))
                self.pendingKey = nil
                self.rankRevision &+= 1
            }
        }
        return rankMemo?.items ?? []
    }

    /// 自定义列表按输入框文本过滤后的结果。
    private var filteredCustom: [IDEPaletteLocation] {
        guard let customItems else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(customItems.prefix(200)) }
        return customItems
            .compactMap { item -> (IDEPaletteLocation, Int)? in
                FuzzyMatcher.match(query: trimmed, path: item.title + " " + item.detail).map { (item, $0.score) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(200)
            .map(\.0)
    }

    /// 主题选择器的键盘监视器:预览换主题会让窗口重绘、输入框丢焦点,
    /// 所以 ↑↓/↩/Esc 不能依赖视图焦点(与中央搜索窗一致,走应用级监视器)。
    @ObservationIgnored private let themeKeys = HubKeyMonitor()

    private func handleThemeKey(_ command: HubKeyCommand) -> Bool {
        guard isPresented, themeRevertID != nil else { return false }
        let list = filteredCustom
        let current = list.indices.contains(highlighted) ? list[highlighted] : nil
        switch command {
        case .move(let step):
            move(step, count: list.count)
            previewTheme(list.indices.contains(highlighted) ? .location(list[highlighted]) : nil)
        case .submit:
            if let id = current?.themeID { commitTheme(id); dismiss() }
        case .dismiss:
            dismiss()
        case .switchSegment:
            return false
        }
        return true
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
        if case .location(let location) = item, let themeID = location.themeID { palette.commitTheme(themeID) }
        palette.dismiss()
        switch item {
        case .file(let match):
            guard let root else { return }
            open((root as NSString).appendingPathComponent(match.path), preview: false)
        case .command(let match):
            palette.recordUse(match.command.id)
            perform(match.command.id)
        case .location(let location):
            if location.themeID != nil { return }
            if let actionID = location.actionID {
                let action = paletteActions.removeValue(forKey: actionID)
                paletteActions = [:]
                if let action { Task { await action() } }
                return
            }
            model.openFile(location.path, line: location.line, preview: false)
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
        case "lsp.symbols": showSymbols()
        case "lsp.references": showReferences()
        case "lsp.rename": renameSymbol()
        case "lsp.codeAction": showCodeActions()
        case "lsp.format": formatDocument()
        case "edit.toggleComment": CodeEditorView.activeEditor()?.perform(.toggleComment)
        case "edit.moveLineUp": CodeEditorView.activeEditor()?.perform(.moveLineUp)
        case "edit.moveLineDown": CodeEditorView.activeEditor()?.perform(.moveLineDown)
        case "edit.addNextOccurrence": CodeEditorView.activeEditor()?.perform(.addNextOccurrence)
        case "edit.fold": CodeEditorView.activeEditor()?.perform(.fold)
        case "edit.unfold": CodeEditorView.activeEditor()?.perform(.unfold)
        case "edit.foldAll": CodeEditorView.activeEditor()?.perform(.foldAll)
        case "edit.unfoldAll": CodeEditorView.activeEditor()?.perform(.unfoldAll)
        case "view.toggleSidebar": model.toggleSidebar()
        case "view.togglePanel": model.togglePanel()
        case "view.toggleAgentPane": model.toggleAgentPane()
        case "view.maximizeAgentPane": model.toggleAgentMaximized()
        case "view.perfHUD": model.perfHUDVisible.toggle()
        case "view.colorTheme": palette.presentThemes()
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
