// @author ixxxxoooo
// 标签内容:会话、文件(EditorKit 只读)、单文件 Diff、本轮改动汇总;其余类型暂以占位说明。

import ACPKit
import ChatKit
import DesignSystem
import DiffKit
import EditorCore
import EditorKit
import GitKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 按标签类型分发内容视图。
struct TabContentView: View {
    let workbench: WorkbenchModel
    let tab: WorkbenchTab

    var body: some View {
        content
            // 标签内容区底色恒定取主题:差异/历史/改动等视图自身没有底色,否则会透出窗口底层的颜色(与主题不一致);文件标签由编辑器自己的主题底色负责
            .background(backgroundColor)
    }

    private var backgroundColor: Color {
        if case .file = tab.kind { return Color(nsColor: EditorTheme.default.background) }
        return OMColors.surface
    }

    @ViewBuilder
    private var content: some View {
        switch tab.kind {
        case .chat(let projectID, let slot): ChatPane(workbench: workbench, projectID: projectID, slot: slot)
        case .file(let path):
            // 预览标签会在同一标签里换文件:按路径重建,滚动位置/语言服务器/对比状态都从干净状态开始,不残留上一个文件的状态
            FileTabView(workbench: workbench, tab: tab, path: path).id(path)
        case .diff(let path): DiffTabView(workbench: workbench, path: path)
        case .changes(let projectID): ChangesTabView(workbench: workbench, projectID: projectID)
        case .subagent(let projectID, let toolCallID): SubagentTabView(workbench: workbench, projectID: projectID, toolCallID: toolCallID)
        case .preview(let id):
            if id == WorkbenchModel.outputTabID {
                LogViewerView()
            } else if id == WorkbenchModel.automationTabID {
                AutomationPage(workbench: workbench)
            } else if id == WorkbenchModel.demoMetricsTabID {
                DemoMetricsTabView()
            } else if id == WorkbenchModel.customizeTabID {
                CustomizePage(workbench: workbench)
            } else if let browserID = WorkbenchModel.browserID(fromTab: id) {
                BrowserTabView(browserID: browserID, workspace: workbench.selectedProjectID ?? NSHomeDirectory()).id(browserID)
            } else if let pane = WorkbenchModel.toolsPane(fromTab: id) {
                ToolsTabView(workbench: workbench, tab: tab, pane: pane)
            } else if let canvasID = WorkbenchModel.canvasID(fromTab: id) {
                CanvasTabView(canvasID: canvasID).id(canvasID)
            } else if let planPath = WorkbenchModel.planPath(fromTab: id) {
                PlanTabView(path: planPath).id(planPath)
            } else {
                PreviewTabView(id: id)
            }
        case .history(let projectID, let path): GitHistoryTabView(workbench: workbench, projectID: projectID, path: path)
        case .blame(let path): GitBlameTabView(workbench: workbench, path: path)
        case .agentTerminal(let projectID, let terminalID): AgentTerminalTabView(workbench: workbench, projectID: projectID, terminalID: terminalID)
        case .terminal(let id):
            // 每个终端就是一个独立标签(不再合并成带终端列表的面板);常驻终端按标签自己的项目根启动,不跟随当前项目
            TerminalTabView(id: id, fallbackDirectory: WorkbenchModel.residentTerminalRoot(id) ?? workbench.selectedProjectID ?? NSHomeDirectory())
        }
    }
}

/// 会话内容:项目会话尚未创建时按需创建。
struct ChatPane: View {
    let workbench: WorkbenchModel
    let projectID: String
    let slot: String?
    private let appearance = AppearanceModel.shared

    var body: some View {
        Group {
            if let model = workbench.conversations[ConversationKey(projectID: projectID, slot: slot)] {
                ChatView(model: model)
                    .id(appearance.renderKey)
                    .environment(model)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { workbench.ensureSession(project: projectID, slot: slot) }
    }
}

/// 文件标签:可编辑的代码编辑器;文本保存在 `FileDocumentStore`,切换标签不丢失未保存内容。
struct FileTabView: View {
    let workbench: WorkbenchModel
    let tab: WorkbenchTab
    let path: String
    /// Files 工作区内嵌时的附加控件(← → 与收起资源管理器);普通文件标签为 nil
    var filesControls: FilesHeaderControls?
    /// 内嵌时面包屑下拉里点选文件的处理(原地打开);nil 表示按默认方式打开标签
    var openInPlace: ((String) -> Void)?
    private let store = FileDocumentStore.shared
    /// 标签是否可见(保活的后台标签不做轮询)
    @Environment(\.tabIsActive) private var isActive
    /// IDE 窗口里的宿主(非 nil 时脏标记、跳转与项目根改走 IDE 窗口;Agent 窗口里为 nil)
    @Environment(\.ideFileHost) var ideHost
    @AppStorage(ClientPrefs.Key.editorLSP) private var lspEnabled = true
    @State private var lsp: EditorLSPController?
    /// 原生编辑器的操作句柄(右键菜单据此执行剪切/粘贴/跳转定义等)
    @State private var editorHandle = NativeEditorHandle()
    /// 最近一次 Agent 改动在新文件中新增的行(仅当文本仍等于 Agent 写入的内容时显示)
    @State private var agentMarks: AgentMarks?
    /// 相对 HEAD 的改动标记(仅 IDE 窗口;按未保存的缓冲区内容计算)
    @State private var gitMarks: [Int: LineMarker] = [:]
    @State private var gutterTask: Task<Void, Never>?
    /// 逐行 blame(仅 IDE 窗口;行末内联显示当前行的作者与时间)
    @State var blameLines: [GitBlameLine] = []
    /// Agent 改动块的审阅状态:已「保留」的块标识与当前所在块序号
    @State var acceptedHunks: Set<Int> = []
    @State var reviewIndex = 0
    /// 是否在编辑区叠加显示「对比 HEAD」的 Git 差异(编辑器保持挂载,切回不丢状态)
    @State private var comparing = false

    /// Agent 改动的行标记快照。
    struct AgentMarks: Equatable {
        var text: String
        var lines: Set<Int>
    }

    var body: some View {
        if let kind = FilePreviewKind.of(path: path), kind.isBinary {
            // 图片 / PDF:只有预览,不当作文本载入
            VStack(spacing: 0) {
                BinaryPreviewTab(path: path, kind: kind)
            }
        } else {
            textBody
        }
    }

    /// 文本文件:编辑器 +(可预览类型的)「源码 / 预览」切换。
    @ViewBuilder
    private var textBody: some View {
        let doc = store.document(for: path)
        let previewKind = FilePreviewKind.of(path: path)
        let mode = previewKind.map { FileViewModeStore.shared.mode(for: path, kind: $0) } ?? .source
        let changesRevision = workbench.allSessions.reduce(0) { $0 + $1.changesRevision }
        let markers: [Int: LineMarker] = {
            guard let marks = agentMarks, doc.text == marks.text else { return gitMarks }
            // Agent 标记优先于 Git 标记
            return gitMarks.merging(marks.lines.map { ($0 - 1, LineMarker.agent) }) { _, agent in agent }
        }()
        VStack(spacing: 0) {
            // Files 工作区内嵌时,面包屑行由工作区通栏绘制
            if filesControls == nil {
            FileHeaderBar(
                path: path, projectRoot: projectRoot(),
                modes: previewKind.map { FileViewMode.available(for: $0) } ?? [],
                mode: mode,
                onMode: { mode in previewKind.map { FileViewModeStore.shared.set(mode, for: $0) } },
                currentText: { doc.text },
                onOpen: { target in
                    if let openInPlace { openInPlace(target) } else if let ideHost { ideHost.open(target, nil, true) } else { workbench.openFile(target, preview: true) }
                },
                isComparing: comparing,
                onToggleCompare: { comparing.toggle() },
                filesControls: filesControls
            )
            }
            banner(doc)
            agentReviewBar(doc)
            Group {
                if let text = doc.text {
                    codeEditor(doc: doc, text: text, markers: markers)
                        .environment(\.tabIsActive, isActive && mode.showsEditor)
                        .opacity(mode.showsEditor ? 1 : 0)
                        .allowsHitTesting(mode.showsEditor)
                        .accessibilityHidden(!mode.showsEditor)
                        .overlay {
                            if mode == .preview, let previewKind {
                                if previewKind == .markdown {
                                    MarkdownPreviewPage(text: text)
                                } else {
                                    TextPreviewView(kind: previewKind, text: text)
                                }
                            }
                        }
                } else if let failure = doc.loadError {
                    Text(failure).foregroundStyle(OMColors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 读盘通常几十毫秒:延迟显示转圈,避免一闪而过
                    DelayedSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 编辑区底色恒定为编辑器主题色:新建编辑器的首帧、加载中、切换文件时都不会透出别的底色(白闪)
            .background(Color(nsColor: EditorTheme.default.background))
            .overlay {
                if comparing {
                    GitFileDiffView(workbench: workbench, path: path, embedded: true)
                        .background(OMColors.surface)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // IDE 窗口里语言服务器状态显示在窗口状态栏,不占编辑区底部
            if ideHost == nil, let lsp, lsp.status != .off { LSPStatusBar(controller: lsp) }
        }
        .onChange(of: doc.isDirty, initial: true) { wasDirty, dirty in
            if let ideHost { ideHost.setDirty(dirty, path) } else { workbench.setDirty(dirty, for: tab.id) }
            if wasDirty, !dirty { lsp?.didSave() }
        }
        .onChange(of: changesRevision, initial: true) {
            refreshAgentMarks()
        }
        .onChange(of: doc.text) { _, newText in
            if let newText { lsp?.textChanged(newText) }
            refreshGutter(newText, delay: .milliseconds(350))
        }
        .onChange(of: ideHost.flatMap { GitStore.shared.model(for: $0.root ?? "").status }) { _, _ in
            refreshGutter(doc.text, delay: .milliseconds(200))
        }
        .onAppear { refreshGutter(doc.text, delay: .zero) }
        .task(id: blameKey(doc)) { await loadBlame(doc) }
        .onChange(of: acceptedHunks) { refreshAgentMarks() }
        .onChange(of: lsp?.diagnostics ?? []) { _, items in
            // IDE 窗口:把诊断汇总到「问题」面板
            ideHost?.report(path, items, doc.text ?? "")
        }
        .task(id: "\(path)|\(lspEnabled)|\(doc.text != nil)") {
            await startLanguageServer(doc)
        }
        .onDisappear {
            lsp?.detach()
            lsp = nil
            ideHost?.registerLSP(path, nil)
            ideHost?.report(path, [], "")
        }
        .task(id: "\(path)|\(isActive)") {
            // Agent 或其它程序改动文件后,未编辑的标签自动刷新;后台标签暂停,切回时立即补一次
            guard isActive else { return }
            await store.checkExternalChange(path)
            // 工作区内由文件系统事件驱动;工作区之外(含切换项目后的旧项目文件)低频轮询磁盘修改时间
            await WorkspaceWatchCenter.shared.follow(path, poll: .seconds(2)) { await store.checkExternalChange(path) }
        }
    }

    /// 原生编辑器的语言智能回调(语言服务器就绪后才有内容)。
    private var nativeServices: NativeLanguageServices {
        guard let lsp, case .ready = lsp.status else { return NativeLanguageServices() }
        return lsp.makeNativeServices()
    }

    /// 语言服务器会话标识:就绪(或换了会话)时变化,驱动原生编辑器重新装入回调。
    private var nativeServicesKey: Int {
        guard let lsp, case .ready = lsp.status else { return 0 }
        return ObjectIdentifier(lsp).hashValue | 1
    }

    /// 原生编辑器右键菜单:先把光标移到点击处(不在选区内时),再按当前状态生成条目。
    private func nativeEditorMenu() -> [MenuEntry] {
        editorHandle.prepareContextMenu()
        return nativeEditorMenuEntries(editorHandle)
    }

    @OMMenuBuilder
    private func nativeEditorMenuEntries(_ handle: NativeEditorHandle) -> [MenuEntry] {
        if handle.supportsDefinition {
            OMMenuItem("跳转到定义", icon: "corner-down-right", shortcut: "F12") { handle.goToDefinition() }
        }
        if handle.supportsReferences {
            OMMenuItem("查找所有引用", icon: "file-search", shortcut: "⇧F12") { handle.findReferences() }
        }
        if handle.supportsCodeActions {
            OMMenuItem("代码操作", icon: "wand-sparkles", shortcut: "⌘.") { handle.showCodeActions() }
        }
        if handle.supportsDefinition || handle.supportsReferences || handle.supportsCodeActions { OMMenuDivider() }
        if handle.supportsInlineEdit {
            OMMenuItem("行内编辑", icon: "sparkles", shortcut: "⌘K") { handle.beginInlineEdit() }
        }
        if handle.supportsReference, handle.hasSelection {
            OMMenuItem("在对话中引用选区", icon: "message-square", shortcut: "⌘L") { handle.referenceSelection() }
        }
        if handle.supportsInlineEdit || (handle.supportsReference && handle.hasSelection) { OMMenuDivider() }
        OMMenuItem("撤销输入", icon: "undo-2", shortcut: "⌘Z", isEnabled: handle.canUndo) { handle.undo() }
        OMMenuItem("重做", shortcut: "⇧⌘Z", isEnabled: handle.canRedo) { handle.redo() }
        OMMenuDivider()
        OMMenuItem("剪切", shortcut: "⌘X", isEnabled: handle.isEditable) { handle.cut() }
        OMMenuItem("复制", icon: "copy", shortcut: "⌘C") { handle.copy() }
        OMMenuItem("粘贴", icon: "clipboard-paste", shortcut: "⌘V", isEnabled: handle.canPaste) { handle.paste() }
        OMMenuItem("全选", shortcut: "⌘A") { handle.selectAll() }
        OMMenuDivider()
        OMMenuItem("查找", icon: "search", shortcut: "⌘F") { handle.find() }
        if handle.supportsFormat {
            OMMenuItem("格式化文档", icon: "list-checks", shortcut: "⇧⌥F") { handle.formatDocument() }
        }
    }

    /// 编辑器本体:按 `EditorEngine` 选择原生 rope 引擎(native2)或 TextKit 引擎。
    @ViewBuilder
    private func codeEditor(doc: FileDocument, text: String, markers: [Int: LineMarker]) -> some View {
        if EditorEngine.current == .native2, let editorDocument = doc.ensureEditorDocument() {
            NativeCodeEditor(document: editorDocument, language: SyntaxLanguage.detect(path: path), isEditable: !doc.isReadOnly,
                             revealLine: tab.line, markers: markers, diagnostics: lsp?.diagnostics ?? [],
                             chrome: ideHost == nil ? [] : [.minimap, .stickyScroll, .folding, .overviewRuler], filePath: path,
                             services: nativeServices, servicesKey: nativeServicesKey,
                             onCaretChange: ideHost.map { host in { host.caret(path, $0) } })
                .handle(editorHandle)
                .agentHooks(agentHooks(doc, editorDocument: editorDocument))
                .omContextMenu { nativeEditorMenu() }
                .id(ObjectIdentifier(editorDocument))
        } else {
            CodeEditor(text: text, language: SyntaxLanguage.detect(path: path), isEditable: !doc.isReadOnly, revealLine: tab.line, markers: markers,
                       diagnostics: lsp?.diagnostics ?? [], features: lsp?.features ?? EditorLanguageFeatures(),
                       onReferenceSelection: { range in referenceSelection(range, text: doc.text ?? text) },
                       chrome: ideHost == nil ? [] : [.minimap, .stickyScroll, .folding],
                       onCaretChange: ideHost.map { host in { host.caret(path, $0) } },
                       inlineNote: !doc.isDirty && !blameLines.isEmpty ? { blameNote($0) } : nil,
                       onChange: { newText in doc.text = newText })
        }
    }

    /// 内联 blame 的刷新键:文件 + 仓库 HEAD + 是否有未保存修改。
    private func blameKey(_ doc: FileDocument) -> String {
        let head = blameRoot.map { GitStore.shared.model(for: $0).status.headOID ?? "" } ?? ""
        return "\(path)|\(head)|\(doc.isDirty)"
    }

    /// 重算相对 HEAD 的行号栏改动标记(IDE 窗口专用;防抖、后台计算、2MB 以上文件不计算)。
    /// - Parameters:
    ///   - text: 当前缓冲区文本
    ///   - delay: 防抖时长
    private func refreshGutter(_ text: String?, delay: Duration) {
        guard let ideHost, let root = ideHost.root, let text, text.utf8.count <= 2_000_000 else {
            if !gitMarks.isEmpty { gitMarks = [:] }
            return
        }
        gutterTask?.cancel()
        let path = path
        gutterTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let git = GitStore.shared.model(for: root)
            if git.repo == nil { await git.refresh(full: false) }
            guard let repo = git.repo, let relative = repo.relativePath(of: path) else {
                if !gitMarks.isEmpty { gitMarks = [:] }
                return
            }
            let old = await repo.committedText(path: relative)
            let marks = await Task.detached(priority: .utility) { LineDiff.gutterMarks(for: LineDiff.diff(old: old, new: text, context: 0)) }.value
            guard !Task.isCancelled else { return }
            let mapped = marks.mapValues { mark -> LineMarker in
                switch mark {
                case .added: .added
                case .modified: .modified
                case .removed: .removed
                }
            }
            if mapped.count != gitMarks.count || mapped.contains(where: { gitMarks[$0.key] != $0.value }) { gitMarks = mapped }
        }
    }

    /// 根据时间线里该文件最近一次 Agent 改动刷新行标记(已回退的改动不标记)。
    private func refreshAgentMarks() {
        // 任一会话的改动修订号变化都会触发这里;结果没变时不重新赋值,避免无谓地重算行标记并刷新编辑器
        func assign(_ marks: AgentMarks?) { if agentMarks != marks { agentMarks = marks } }
        guard let found = latestChange(for: path, in: workbench), found.change.status == .pending || found.change.status == .partiallyReverted else {
            assign(nil)
            return
        }
        let lines = AgentHunkKey.pending(found.change.diff.hunks, accepted: acceptedHunks).flatMap(\.lines).filter { $0.kind == .added }.compactMap(\.newNumber)
        assign(lines.isEmpty ? nil : AgentMarks(text: found.change.current, lines: Set(lines)))
    }

    /// 把选区引用(`@文件:行范围`)追加到所属项目的输入框并切到对话标签。
    func referenceSelection(_ range: NSRange, text: String) {
        // 空选区(⌘L):只切到并聚焦对话输入框
        if range.length == 0 {
            if let ideHost { ideHost.focusAgent() } else { workbench.select(project: projectRoot()) }
            return
        }
        if let ideHost {
            // IDE 窗口:引用追加到本窗口 Agent 面板的输入框
            ideHost.reference(EditorReference.token(path: path, projectRoot: projectRoot(), text: text, range: range))
            return
        }
        let root = projectRoot()
        guard workbench.projects.contains(where: { $0.id == root }), let session = workbench.ensureSession(for: root) else { return }
        let token = EditorReference.token(path: path, projectRoot: root, text: text, range: range)
        session.draft = EditorReference.appending(token, to: session.draft)
        workbench.select(project: root)
        Log.ui.info("引用选区到对话", ["file": (path as NSString).lastPathComponent, "token": token])
    }

    /// 文本加载完成后接入语言服务器(开关关闭、文件过大或类型不支持时不启动)。
    private func startLanguageServer(_ doc: FileDocument) async {
        lsp?.detach()
        lsp = nil
        guard lspEnabled, let text = doc.text, !doc.isReadOnly, EditorLSPController.isSupported(path: path) else { return }
        let controller = EditorLSPController(path: path, projectRoot: projectRoot())
        if let ideHost {
            controller.openLocation = { target, line in MainActor.assumeIsolated { ideHost.open(target, line, false) } }
        } else {
            controller.openLocation = { [weak workbench] target, line in workbench?.openFile(target, line: line, preview: false) }
        }
        lsp = controller
        await controller.attach(text: text)
        ideHost?.registerLSP(path, controller)
    }

    /// 文件所属项目的根目录(取最长匹配);不在任何项目内则用文件所在目录。
    func projectRoot() -> String {
        if let root = ideHost?.root, path.hasPrefix(root + "/") { return root }
        let match = workbench.projects.map(\.id)
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        return match ?? (path as NSString).deletingLastPathComponent
    }

    /// 只读与外部修改提示条。
    @ViewBuilder
    private func banner(_ doc: FileDocument) -> some View {
        if doc.isReadOnly {
            noticeBar(icon: "lock", text: String(localized: "文件超过 5 MB,以只读方式打开")) { EmptyView() }
        } else if doc.externalChange {
            noticeBar(icon: "triangle-alert", text: String(localized: "文件已在磁盘上被修改,与你的未保存编辑冲突")) {
                Button("重新载入") { Task { await store.reload(path) } }.controlSize(.small)
                Button("保留我的") { Task { await store.save(path); AppActions.shared.refreshDirtyFlags() } }.controlSize(.small)
            }
        }
    }

    private func noticeBar<Actions: View>(icon: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image.om(icon, size: 13).foregroundStyle(OMColors.warning)
            Text(text).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Spacer()
            actions()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(OMColors.warning.opacity(0.12))
    }
}

/// 在所有会话的时间线中查找某文件最近一次改动。
@MainActor
func latestChange(for path: String, in workbench: WorkbenchModel) -> (model: SessionModel, change: FileChange)? {
    for model in workbench.allSessions {
        for entry in model.timeline.entries.reversed() where entry.kind == .changes {
            if let change = entry.changes.first(where: { $0.path == path }) { return (model, change) }
        }
    }
    return nil
}

/// 单文件 Diff 标签。
struct DiffTabView: View {
    let workbench: WorkbenchModel
    let path: String
    /// 并排/统一显示模式,跨标签记忆
    @AppStorage("diff.sideBySide") private var sideBySide = true

    var body: some View {
        if let found = latestChange(for: path, in: workbench) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text((path as NSString).abbreviatingWithTildeInPath).font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                        Text("+\(found.change.diff.added)").foregroundStyle(OMColors.diffAdded)
                        Text("−\(found.change.diff.removed)").foregroundStyle(OMColors.diffRemoved)
                        Spacer()
                        OMCompactSegmented(
                            options: [(value: true, title: "并排"), (value: false, title: "统一")],
                            selection: $sideBySide,
                            accessibilityName: String(localized: "Diff 显示模式")
                        )
                        Button("在编辑器中打开") { workbench.openFile(path, line: found.change.diff.hunks.first?.newStart, preview: false) }
                            .controlSize(.small)
                        if found.change.status == .pending || found.change.status == .partiallyReverted {
                            Button("撤销") { found.model.revert(found.change) }.controlSize(.small)
                        }
                    }
                    .font(OMFonts.small)
                    let revert: ((Int) -> Void)? = found.change.status == .reverted ? nil : { hunk in
                        found.model.revert(found.change, hunks: [hunk])
                    }
                    if sideBySide {
                        SideBySideDiffView(diff: found.change.diff, onRevertHunk: revert)
                    } else {
                        DiffView(diff: found.change.diff, onRevertHunk: revert)
                    }
                }
                .padding(14)
            }
        } else {
            // Agent 没有改过这个文件 → 退回到 Git 差异
            GitFileDiffView(workbench: workbench, path: path)
        }
    }
}

/// 本轮改动汇总标签。
struct ChangesTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    /// 指定承载会话(IDE 窗口的 Agent 面板可能不是项目的当前会话);为空取项目当前会话
    var session: SessionModel?

    var body: some View {
        if let model = session ?? workbench.sessions[projectID],
           let entry = model.timeline.entries.last(where: { $0.kind == .changes && !$0.changes.isEmpty }) {
            ScrollView {
                ChangesSummaryView(entry: entry)
                    .environment(model)
                    .padding(14)
            }
        } else {
            OMEmptyState {
                Label("暂无改动", om: "file-diff", size: 28)
            } description: {
                Text("Agent 修改文件后,这里会列出每个文件的差异。")
            }
        }
    }
}

/// Agent 终端标签:只读查看 Agent 正在(或刚刚)执行的命令输出。
struct AgentTerminalTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    let terminalID: String

    var body: some View {
        if let model = workbench.sessions[projectID], let session = model.terminals[terminalID] {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image.om("terminal", size: 13).foregroundStyle(OMColors.secondaryText)
                    Text("Agent 正在使用这个终端,只读").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                Divider()
                TerminalOutputView(session: session, fillHeight: true, onInterrupt: session.isExternal ? nil : { model.interruptTerminal(terminalID) }, onRetryUnsandboxed: { model.retryWithoutSandbox() })
                    .padding(12)
            }
            .background(OMColors.surface)
        } else {
            OMEmptyState {
                Label("这个终端已不可用", om: "terminal", size: 28)
            } description: {
                Text("会话被切换或重置后,原来的终端输出不会保留。")
            }
        }
    }
}

/// 文件标签底部的语言服务器状态条:服务器状态与诊断统计。
struct LSPStatusBar: View {
    let controller: EditorLSPController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.status {
            case .off:
                EmptyView()
            case .starting:
                OMSpinner(.mini)
                Text("语言服务器启动中…").foregroundStyle(OMColors.secondaryText)
            case .ready(let name):
                Image.om("circle-check", size: 12).foregroundStyle(OMColors.success)
                Text(name).foregroundStyle(OMColors.secondaryText)
                Spacer()
                if controller.errorCount == 0, controller.warningCount == 0 {
                    Text("没有问题").foregroundStyle(OMColors.secondaryText)
                } else {
                    HStack(spacing: 3) {
                        Image.om("circle-x", size: 12)
                        Text("\(controller.errorCount)")
                    }
                    .foregroundStyle(OMColors.danger)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(controller.errorCount) 个错误")
                    HStack(spacing: 3) {
                        Image.om("triangle-alert", size: 12)
                        Text("\(controller.warningCount)")
                    }
                    .foregroundStyle(OMColors.warning)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(controller.warningCount) 个警告")
                }
            case .unavailable(let hint):
                Image.om("info", size: 12).foregroundStyle(OMColors.secondaryText)
                Text("未找到语言服务器:\(hint)").foregroundStyle(OMColors.secondaryText).lineLimit(1)
                LSPInstallButton(controller: controller)
            case .failed(let message):
                Image.om("triangle-alert", size: 12).foregroundStyle(OMColors.warning)
                Text("语言服务器不可用:\(message)").foregroundStyle(OMColors.secondaryText).lineLimit(1)
            }
            if case .ready = controller.status {} else { Spacer() }
        }
        .font(OMFonts.small)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}


/// 延迟出现的加载转圈(短暂加载不显示,避免闪一下)。
struct DelayedSpinner: View {
    @State private var visible = false

    var body: some View {
        OMSpinner(.regular)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                visible = true
            }
    }
}

/// 「安装」按钮:在终端里运行安装命令(没有自动安装方式的服务器不显示)。安装完成后重新打开文件即可生效。
struct LSPInstallButton: View {
    let controller: EditorLSPController

    var body: some View {
        if let command = controller.missingKind?.installCommand {
            Button("安装") { AppActions.shared.runInNewTerminal(command) }
                .buttonStyle(.omSecondary)
                .omTooltip(String(localized: "在终端运行:\(command)\n安装完成后重新打开文件即可生效"))
        }
    }
}

/// IDE 状态栏里的语言服务器状态(紧凑):就绪显示名称,启动中显示转圈,不可用/失败显示提示(悬停看详情)。
struct LSPStatusItem: View {
    let controller: EditorLSPController

    var body: some View {
        switch controller.status {
        case .off:
            EmptyView()
        case .starting:
            HStack(spacing: 4) {
                OMSpinner(.mini)
                Text("语言服务器启动中…")
            }
        case .ready(let name):
            HStack(spacing: 4) {
                Image.om("circle-check", size: 12).foregroundStyle(OMColors.success)
                Text(name)
            }
        case .unavailable(let hint):
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image.om("info", size: 12)
                    Text("未找到语言服务器")
                }
                .omTooltip(hint)
                LSPInstallButton(controller: controller)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Image.om("triangle-alert", size: 12).foregroundStyle(OMColors.warning)
                Text("语言服务器不可用")
            }
            .omTooltip(message)
        }
    }
}
