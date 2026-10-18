// @author ixxxxoooo
// 标签内容:会话、文件(EditorKit 只读)、单文件 Diff、本轮改动汇总;其余类型暂以占位说明。

import ACPKit
import ChatKit
import DesignSystem
import DiffKit
import EditorKit
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
            } else if id == WorkbenchModel.customizeTabID {
                CustomizePage(workbench: workbench)
            } else if let browserID = WorkbenchModel.browserID(fromTab: id) {
                BrowserTabView(browserID: browserID, workspace: workbench.selectedProjectID ?? NSHomeDirectory()).id(browserID)
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
            TerminalTabView(id: id, fallbackDirectory: workbench.selectedProjectID ?? NSHomeDirectory())
        }
    }
}

/// 会话内容:项目会话尚未创建时按需创建。
private struct ChatPane: View {
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
    private let store = FileDocumentStore.shared
    /// 标签是否可见(保活的后台标签不做轮询)
    @Environment(\.tabIsActive) private var isActive
    @AppStorage(ClientPrefs.Key.editorLSP) private var lspEnabled = true
    @State private var lsp: EditorLSPController?
    /// 最近一次 Agent 改动在新文件中新增的行(仅当文本仍等于 Agent 写入的内容时显示)
    @State private var agentMarks: AgentMarks?
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
            BinaryPreviewTab(path: path, kind: kind)
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
        let markdownMode: MarkdownEditorMode = .off
        let changesRevision = workbench.allSessions.reduce(0) { $0 + $1.changesRevision }
        let markers: [Int: LineMarker] = {
            guard let marks = agentMarks, doc.text == marks.text else { return [:] }
            return Dictionary(uniqueKeysWithValues: marks.lines.map { ($0 - 1, LineMarker.agent) })
        }()
        VStack(spacing: 0) {
            FileHeaderBar(
                path: path, projectRoot: projectRoot(),
                modes: previewKind.map { FileViewMode.available(for: $0) } ?? [],
                mode: mode,
                onMode: { mode in previewKind.map { FileViewModeStore.shared.set(mode, for: $0) } },
                currentText: { doc.text },
                onOpen: { workbench.openFile($0, preview: true) },
                isComparing: comparing,
                onToggleCompare: { comparing.toggle() }
            )
            banner(doc)
            Group {
                if let text = doc.text {
                    CodeEditor(text: text, language: SyntaxLanguage.detect(path: path), isEditable: !doc.isReadOnly, revealLine: tab.line, markers: markers,
                               diagnostics: lsp?.diagnostics ?? [], features: lsp?.features ?? EditorLanguageFeatures(),
                               onReferenceSelection: { range in referenceSelection(range, text: doc.text ?? text) },
                               markdownMode: markdownMode,
                               onChange: { newText in doc.text = newText })
                        .environment(\.tabIsActive, isActive && mode.showsEditor)
                        .opacity(mode.showsEditor ? 1 : 0)
                        .allowsHitTesting(mode.showsEditor)
                        .accessibilityHidden(!mode.showsEditor)
                        .overlay {
                            if mode == .preview, let previewKind {
                                TextPreviewView(kind: previewKind, text: text)
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
            if let lsp, lsp.status != .off { LSPStatusBar(controller: lsp) }
        }
        .onChange(of: doc.isDirty, initial: true) { wasDirty, dirty in
            workbench.dock.setDirty(dirty, for: tab.id)
            if wasDirty, !dirty { lsp?.didSave() }
        }
        .onChange(of: changesRevision, initial: true) {
            refreshAgentMarks()
        }
        .onChange(of: doc.text) { _, newText in
            if let newText { lsp?.textChanged(newText) }
        }
        .task(id: "\(path)|\(lspEnabled)|\(doc.text != nil)") {
            await startLanguageServer(doc)
        }
        .onDisappear {
            lsp?.detach()
            lsp = nil
        }
        .task(id: "\(path)|\(isActive)") {
            // 轮询磁盘修改时间:Agent 或其它程序改动文件后,未编辑的标签自动刷新;后台标签暂停,切回时立即补一次
            guard isActive else { return }
            await store.checkExternalChange(path)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await store.checkExternalChange(path)
            }
        }
    }

    /// 根据时间线里该文件最近一次 Agent 改动刷新行标记(已回退的改动不标记)。
    private func refreshAgentMarks() {
        guard let found = latestChange(for: path, in: workbench), found.change.status == .pending || found.change.status == .partiallyReverted else {
            agentMarks = nil
            return
        }
        let lines = found.change.diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.compactMap(\.newNumber)
        agentMarks = lines.isEmpty ? nil : AgentMarks(text: found.change.current, lines: Set(lines))
    }

    /// 把选区引用(`@文件:行范围`)追加到所属项目的输入框并切到对话标签。
    private func referenceSelection(_ range: NSRange, text: String) {
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
        controller.openLocation = { [weak workbench] target, line in workbench?.openFile(target, line: line, preview: false) }
        lsp = controller
        await controller.attach(text: text)
    }

    /// 文件所属项目的根目录(取最长匹配);不在任何项目内则用文件所在目录。
    private func projectRoot() -> String {
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
private func latestChange(for path: String, in workbench: WorkbenchModel) -> (model: SessionModel, change: FileChange)? {
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

    var body: some View {
        if let model = workbench.sessions[projectID],
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

/// 子 Agent 标签:只读展示子 Agent 的完整会话(含内部工具行、分组与实时状态)。
struct SubagentTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    let toolCallID: String
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var chatWidthCustom = ChatWidth.customDefault

    var body: some View {
        if let model = workbench.sessions[projectID],
           let entry = model.timeline.toolEntry(id: toolCallID), let tool = entry.tool {
            VStack(spacing: 0) {
                header(tool: tool, entry: entry)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let child = entry.childStore, !child.entries.isEmpty {
                            ForEach(TimelineGrouping.group(child.entries)) { item in
                                TimelineItemView(item: item)
                            }
                        } else {
                            Text("子 Agent 还没有产生内容").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
                        }
                    }
                    .frame(maxWidth: ChatWidth.resolve(raw: chatWidth, custom: chatWidthCustom), alignment: .leading)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top)
                Divider()
                SubagentStatusFooter(entry: entry, tool: tool)
            }
            .environment(model)
            .background(OMColors.surface)
        } else {
            OMEmptyState {
                Label("这个子任务已不可用", om: "bot", size: 28)
            } description: {
                Text("会话被切换或重置后,原来的子任务内容不会保留。")
            }
        }
    }

    private func header(tool: ToolCall, entry: TimelineEntry) -> some View {
        HStack(spacing: 8) {
            Image.om("bot", size: 14).foregroundStyle(OMColors.accent)
            Text(tool.title).font(OMFonts.body.weight(.medium)).lineLimit(1)
            if tool.status.isTerminal {
                OMTag(tool.status == .failed ? String(localized: "失败") : String(localized: "已完成"), tint: tool.status == .failed ? OMColors.danger : OMColors.success)
            } else {
                OMTag(String(localized: "运行中"), tint: OMColors.accent)
            }
            Spacer()
            Text("只读").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

/// 子 Agent 标签底部的状态行:运行中与主会话一致(动画字符 + 动词 + 耗时),
/// 结束后显示终态与统计(用时、工具调用次数、token——结果里带才显示)并可复制。
struct SubagentStatusFooter: View {
    let entry: TimelineEntry
    let tool: ToolCall
    @AppStorage(ClientPrefs.Key.workingVerbStyle) private var verbStyleRaw = WorkingVerbStyle.classic.rawValue

    var body: some View {
        Group {
            if tool.status.isTerminal { finished } else { running }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 运行中:不提示 Esc(子 Agent 不能单独中断,只能在主会话停止本轮)。
    private var running: some View {
        let style = WorkingVerbStyle.resolve(verbStyleRaw)
        return ActiveTimeline(interval: 1, start: entry.startedAt) { date in
            let seconds = Int(date.timeIntervalSince(entry.startedAt))
            HStack(spacing: 8) {
                OMGlyphCycle(frames: style.glyphFrames, resting: style.restingGlyph, font: OMFonts.body.weight(.medium), color: OMColors.accent)
                Text(WorkingStatus.line(verb: WorkingStatus.verb(seed: Int(entry.startedAt.timeIntervalSince1970), style: style), seconds: seconds, canInterrupt: false))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .omTooltip("子 Agent 不能单独中断:在主会话点「停止」会停止本轮及其所有子 Agent")
    }

    /// 已结束:终态 + 统计 + 复制。
    @ViewBuilder
    private var finished: some View {
        let failed = tool.status == .failed
        HStack(spacing: 8) {
            Image.om(failed ? "circle-x" : "circle-check", size: 13)
                .foregroundStyle(failed ? OMColors.danger : OMColors.success)
                .frame(width: 16)
            if let summary = SubagentSummary.make(entry: entry) {
                Text(([failed ? String(localized: "已失败") : String(localized: "已完成")] + summary.parts).joined(separator: " · "))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                ModelCopyButton(text: summary.copyText, label: String(localized: "复制统计信息"))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
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
