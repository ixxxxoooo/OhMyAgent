// @author ixxxxoooo
// Cursor 风格的紧凑工具行:一行摘要(动词 + 对象 + 附注 + 统计 + 状态),点击展开详情;
// 连续的“浏览”类步骤折叠为一组;终端输出支持 ANSI 颜色、复制、耗时与中断。

import IconKit
import ACPKit
import AppKit
import ChatKit
import DesignSystem
import SwiftUI

// MARK: - 图标

/// 工具图标映射。
enum ToolIcons {
    static func symbol(for kind: ToolKind) -> String {
        switch kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .think: return "brain"
        case .fetch: return "network"
        case .switchMode: return "arrow.triangle.swap"
        case .other: return "wrench.and.screwdriver"
        }
    }

    static func symbol(for category: ToolPresentation.Category) -> String {
        switch category {
        case .read: return "doc.text"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .terminal: return "terminal"
        case .fetch: return "network"
        case .mcp: return "puzzlepiece.extension"
        case .subagent: return "person.2"
        case .plan: return "checklist"
        case .think: return "brain"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// 调试开关(脚本化界面验证):`OMA_EXPAND_ALL=1` 时所有工具与分组默认展开。
enum DebugFlags {
    static let expandAll = ProcessInfo.processInfo.environment["OMA_EXPAND_ALL"] != nil
}

/// 把工具给出的路径解析为绝对路径(相对路径以工作区为基准)。
@MainActor
func resolveToolPath(_ path: String, workspace: String) -> String {
    path.hasPrefix("/") ? path : (workspace as NSString).appendingPathComponent(path)
}

// MARK: - 工具行

/// 紧凑工具行 + 可展开详情。
struct ToolRowView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model
    @Environment(\.stickyUser) private var scrollState
    @State private var expanded: Bool?
    @State private var hovering = false
    @State private var stats: DiffStats?
    @AppStorage(ClientPrefs.Key.toolDensity) private var densityRaw = ToolDensity.standard.rawValue

    /// 工具调用详细程度。
    private var density: ToolDensity { ToolDensity(rawValue: densityRaw) ?? .standard }

    /// 新增/删除行统计。
    struct DiffStats: Equatable { var added: Int; var removed: Int }

    var body: some View {
        if let tool = entry.tool {
            let presentation = ToolPresentation(tool: tool, hasChild: entry.childStore != nil)
            let canExpand = hasDetails(tool, presentation)
            let isExpanded = canExpand && (expanded ?? defaultExpanded(tool, presentation))
            VStack(alignment: .leading, spacing: 0) {
                row(tool, presentation, canExpand: canExpand, isExpanded: isExpanded)
                // 子代理:行下方给出实时状态卡片(启动中/运行中/已完成、待办计数、当前活动),点击在标签页打开
                if presentation.category == .subagent {
                    SubagentCardView(entry: entry)
                        .padding(.leading, 23)
                        .padding(.bottom, 2)
                }
                // Canvas 工具完成后,在工具行下方给出可点击的画布卡片
                if let ref = CanvasToolRef.of(tool) {
                    CanvasCardView(ref: ref)
                        .padding(.leading, 23)
                        .padding(.vertical, 6)
                }
                if isExpanded {
                    detailsBlock(tool, presentation)
                        .padding(.leading, 23)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .task(id: "\(tool.status)-\(tool.content.count)") {
                let snapshot = tool
                let result = await Task.detached(priority: .utility) { ToolPresentation.diffStats(of: snapshot) }.value
                stats = result.map { DiffStats(added: $0.added, removed: $0.removed) }
            }
        }
    }

    // MARK: 详情(含「详细」档的内联预览)

    /// 详情区:「详细」档下默认展开的编辑/写入/命令只显示前一段预览(硬裁切 + 「显示全部」,不做淡出),用户点开后显示完整内容。
    @ViewBuilder
    private func detailsBlock(_ tool: ToolCall, _ p: ToolPresentation) -> some View {
        if let outcome = outcome(of: tool) {
            QuestionAnswerView(outcome: outcome)
        } else {
            standardDetails(tool, p)
        }
    }

    /// 提问结果:实时回答写入的快照优先,否则尝试从历史工具调用还原。
    private func outcome(of tool: ToolCall) -> ElicitationOutcome? {
        entry.elicitationOutcome ?? ElicitationOutcome.replayed(from: tool)
    }

    @ViewBuilder
    private func standardDetails(_ tool: ToolCall, _ p: ToolPresentation) -> some View {
        let details = ToolDetailsView(entry: entry, tool: tool, presentation: p)
        if expanded == nil, density == .detailed, !DebugFlags.expandAll {
            VStack(alignment: .leading, spacing: 4) {
                details
                    .frame(maxHeight: Self.previewHeight, alignment: .top)
                    .clipped()
                Button("显示全部") { expanded = true }
                    .buttonStyle(.omPlain)
                    .font(OMFonts.caption)
            }
        } else {
            details
        }
    }

    /// 「详细」档内联预览的最大高度。
    private static let previewHeight: CGFloat = 180

    // MARK: 行

    private func row(_ tool: ToolCall, _ p: ToolPresentation, canExpand: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: 7) {
            leadingIcon(tool, p)
            if let server = p.mcpServer { OMTag(server, tint: OMColors.accent) }
            if let agentType = p.agentType { OMTag(agentType, tint: OMColors.accent) }
            if !p.verb.isEmpty {
                Text(p.verb)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
            }
            if describedCommand(p) {
                // 命令带 description(Agent 写的一句说明)时,行内直接显示说明,具体命令放进展开详情
                Text(p.detail ?? "")
                    .font(OMFonts.small)
                    .foregroundStyle(tool.status == .failed ? OMColors.danger : OMColors.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                subject(p, failed: tool.status == .failed)
            }
            if !describedCommand(p), let detail = p.detail, !detail.isEmpty {
                Text(detail)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
            }
            if hovering, let path = openablePath(tool, p) {
                Button {
                    model.viewerRequest = FileViewRequest(path: path, line: tool.locations.first?.line)
                } label: {
                    Image.om("arrow.up.right.square", size: 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("打开文件")
                .accessibilityLabel("打开 \((path as NSString).lastPathComponent)")
            }
            if entry.childStore != nil, let tool = entry.tool {
                Button {
                    let workbench = AppEnvironment.shared.workbench
                    if let project = workbench.projectID(of: model) {
                        workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
                    }
                } label: {
                    Image.om("square-arrow-out-up-right", size: 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .opacity(hovering ? 1 : 0.55)
                .omTooltip("在标签中打开子 Agent 会话")
                .accessibilityLabel("在标签中打开子 Agent 会话")
            }
            if let stats, stats.added + stats.removed > 0 {
                HStack(spacing: 4) {
                    if stats.added > 0 { Text("+\(stats.added)").foregroundStyle(OMColors.diffAdded) }
                    if stats.removed > 0 { Text("−\(stats.removed)").foregroundStyle(OMColors.diffRemoved) }
                }
                .font(OMFonts.monoSmall)
            }
            durationText(tool)
            statusView(tool.status)
            if canExpand {
                Image.om("chevron.right", size: 9, weight: .bold)
                    .foregroundStyle(OMColors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.15), value: isExpanded)
                    .opacity(hovering || isExpanded ? 1 : 0)
            }
        }
        // 纯文字行(对齐 Cursor):贴合内容宽度,没有整行底色长条与右侧对齐的状态列;
        // 悬停时才显现箭头,点击区域只在内容上
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { handleTap(tool, p, canExpand: canExpand, isExpanded: isExpanded) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.plainText),\(Self.statusText(tool.status))")
        .accessibilityAddTraits(canExpand || openablePath(tool, p) != nil ? .isButton : [])
        .omContextMenu {
            if p.category == .subagent {
                if entry.childStore != nil {
                    OMMenuItem("在标签中打开子 Agent 会话", icon: "external-link") {
                        let workbench = AppEnvironment.shared.workbench
                        if let project = workbench.projectID(of: model) {
                            workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
                        }
                    }
                }
                OMMenuItem("查看子 Agent 定义…", icon: "bot") { AppActions.shared.openSettings(page: .subagents) }
            }
        }
    }

    /// 命令是否带说明:终端工具有非空 `description` 时,行内以说明代替命令原文。
    private func describedCommand(_ p: ToolPresentation) -> Bool {
        p.category == .terminal && !(p.detail ?? "").isEmpty
    }

    /// 点击行:无详情可展开时直接在编辑器打开文件(如 Antigravity 的读取类工具不回传内容),否则展开/折叠。
    private func handleTap(_ tool: ToolCall, _ p: ToolPresentation, canExpand: Bool, isExpanded: Bool) {
        guard canExpand else {
            if let path = openablePath(tool, p) {
                model.viewerRequest = FileViewRequest(path: path, line: tool.locations.first?.line)
            }
            return
        }
        // 展开/折叠不做整体高度动画:惰性栈里动画重排会让点击明显卡顿;箭头自带小动画
        scrollState?.followSuspended = true
        expanded = !isExpanded
    }

    /// 行首图标:固定为工具类型的功能图标;文件的彩色类型图标紧贴文件名(见 `subject`)。
    @ViewBuilder
    private func leadingIcon(_ tool: ToolCall, _ p: ToolPresentation) -> some View {
        Image.om(ElicitationOutcome.isAskQuestion(tool) ? "message-circle-question-mark" : ToolIcons.symbol(for: p.category), size: 11.5)
            .frame(width: 16)
            .foregroundStyle(tool.status == .failed ? OMColors.danger : OMColors.secondaryText)
    }

    /// 这类工具的对象是文件:文件名前显示彩色文件类型图标。
    private static let fileCategories: Set<ToolPresentation.Category> = [.read, .write, .edit, .delete, .move]

    @ViewBuilder
    private func subject(_ p: ToolPresentation, failed: Bool) -> some View {
        if p.subjectIsPath {
            let name = (p.subject as NSString).lastPathComponent
            HStack(spacing: 5) {
                if !name.isEmpty, Self.fileCategories.contains(p.category) {
                    OMFileIcon(name: name, size: OMMetrics.fileIconInline)
                        .opacity(failed ? 0.5 : 1)
                }
                Text(name)
                    .font(OMFonts.small.weight(.medium))
                    .foregroundStyle(failed ? OMColors.danger : OMColors.primaryText)
            }
            .lineLimit(1)
            .omTooltip(p.subject)
        } else if p.category == .terminal {
            // 命令按 shell 语法高亮;只取第一行作摘要
            ShellCommandText(command: p.subject.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? p.subject, lineLimit: 1, failed: failed, selectable: false)
        } else if p.category == .search {
            Text(p.subject)
                .font(OMFonts.monoSmall)
                .foregroundStyle(failed ? OMColors.danger : OMColors.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(p.subject)
                .font(OMFonts.small.weight(.medium))
                .foregroundStyle(failed ? OMColors.danger : OMColors.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func durationText(_ tool: ToolCall) -> some View {
        if tool.status.isTerminal {
            // 已结束且不到 1 秒的不显示耗时(历史回放里恒为 0.0 秒,只是噪音)
            if entry.elapsedSeconds >= 1 {
                Text(Self.format(entry.elapsedSeconds))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
            }
        } else {
            ActiveTimeline(interval: 1) { _ in
                Text(Self.format(entry.elapsedSeconds))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private func statusView(_ status: ToolStatus) -> some View {
        switch status {
        case .pending: OMStatusDot(.idle)
        case .inProgress: OMSpinner(.mini)
        case .completed: EmptyView()   // 成功不加勾,只在进行中/失败时标示状态
        case .failed: Image.om("xmark", size: 9, weight: .bold).foregroundStyle(OMColors.danger)
        }
    }

    // MARK: 策略

    /// 可在工作台打开的文件路径(读/写/编辑类)。
    private func openablePath(_ tool: ToolCall, _ p: ToolPresentation) -> String? {
        guard p.subjectIsPath || !tool.locations.isEmpty, [.read, .write, .edit].contains(p.category) else { return nil }
        let path = p.subjectIsPath ? p.subject : (tool.locations.first?.path ?? "")
        return path.isEmpty ? nil : resolveToolPath(path, workspace: model.workspace.path)
    }

    /// 是否有可展开的详情。
    private func hasDetails(_ tool: ToolCall, _ p: ToolPresentation) -> Bool {
        if outcome(of: tool) != nil { return true }
        if !tool.content.isEmpty || entry.childStore != nil { return true }
        // 不经 content 回传结果的 Agent(Antigravity):结果在 rawOutput;失败原因必须能看到
        if tool.resultText != nil || tool.failureText != nil { return true }
        if p.category == .mcp, tool.rawInput != nil { return true }
        // 行内显示的是说明而不是命令,命令必须能在详情里看到
        if describedCommand(p), tool.rawInput?["command"]?.stringValue != nil { return true }
        if p.category == .terminal, let command = tool.rawInput?["command"]?.stringValue, command.contains("\n") || command.count > 80 { return true }
        if [.edit, .write].contains(p.category) {
            if tool.rawInput?["new_string"] != nil || tool.rawInput?["newText"] != nil
                || tool.rawInput?["ReplacementContent"] != nil || tool.rawInput?["CodeContent"] != nil
                || tool.rawInput?["content"] != nil {
                return true
            }
            let path = p.subjectIsPath ? p.subject : (tool.locations.first?.path ?? "")
            if !path.isEmpty && model.hasTurnChange(at: path) { return true }
        }
        return false
    }

    /// 默认展开策略:标准/精简档折叠(Diff、运行中都不自动展开),由用户点击行自行展开;
    /// 例外:标准档下失败的命令自动展开输出(出错时最需要看细节);
    /// 「详细」档下编辑/写入/命令默认展开为内联预览;调试开关 `OMA_EXPAND_ALL` 可在脚本化截图时强制展开。
    private func defaultExpanded(_ tool: ToolCall, _ p: ToolPresentation) -> Bool {
        if DebugFlags.expandAll { return true }
        // 提问结果(问了什么、怎么答的)默认展开
        if entry.elicitationOutcome != nil { return true }
        // 已完成且返回了图片(浏览器截图、读取图片):图片本身就是结果,默认展开
        if tool.status == .completed, tool.content.contains(where: { if case .content(.image) = $0 { return true } else { return false } }) { return true }
        // 标准档:命令失败时展开输出
        if density == .standard, p.category == .terminal, tool.status == .failed { return true }
        // 「详细」档:编辑/写入/命令默认带内联预览;其余仍折叠
        return density == .detailed && [.edit, .write, .terminal].contains(p.category)
    }

    static func statusText(_ status: ToolStatus) -> String {
        switch status {
        case .pending: return String(localized: "等待中")
        case .inProgress: return String(localized: "进行中")
        case .completed: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        }
    }

    /// 耗时格式:<10 秒保留一位小数。
    static func format(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: String(localized: "%.1f 秒"), seconds) }
        if seconds < 60 { return String(localized: "\(Int(seconds)) 秒") }
        return String(localized: "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒")
    }
}

// MARK: - 详情

/// 工具详情:按类别渲染内容。
struct ToolDetailsView: View {
    let entry: TimelineEntry
    let tool: ToolCall
    let presentation: ToolPresentation
    @Environment(SessionModel.self) private var model
    @AppStorage(ClientPrefs.Key.toolDensity) private var densityRaw = ToolDensity.standard.rawValue

    /// 工具调用详细程度(子 Agent 内嵌分组沿用)。
    private var density: ToolDensity { ToolDensity(rawValue: densityRaw) ?? .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.category == .mcp, let input = tool.rawInput, input.objectValue?.isEmpty != true {
                KeyValueBox(title: String(localized: "入参"), value: input)
            }
            if presentation.category == .terminal, !hasTerminalContent,
               let command = tool.rawInput?["command"]?.stringValue {
                let output = plainOutput.isEmpty ? (tool.resultText ?? "") : plainOutput
                CommandBox(command: command, output: output, status: tool.status, exitCode: tool.exitCode,
                           copyText: command + (output.isEmpty ? "" : "\n" + ToolOutputText.stripFence(output)))
            } else if !hasTextContent, !showsTerminalSession, let text = tool.resultText {
                rawResultView(text)
            }
            if presentation.category != .terminal, let failure = tool.failureText, !failure.isEmpty, !hasTextContent {
                ToolErrorBox(text: failure)
            }
            ForEach(Array(tool.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }
            if !hasDiffContent, [.edit, .write].contains(presentation.category),
               let diff = fallbackDiff {
                SnippetDiffView(path: diff.path, oldText: diff.oldText, newText: diff.newText, showHeader: false)
            }
            if let child = entry.childStore, !child.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TimelineGrouping.group(child.entries, density: density)) { item in
                        TimelineItemView(item: item)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OMColors.hairline).frame(width: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `content` 里是否已有文本结果(有就不再重复展示 `rawOutput`)。
    private var hasTextContent: Bool {
        tool.content.contains { if case .content(let block) = $0 { return block.plainText?.isEmpty == false } else { return false } }
    }

    /// `rawOutput` 里的文本结果:搜索类按结果列表渲染,其余走普通文本框(失败时由 `ToolErrorBox` 单独展示)。
    @ViewBuilder
    private func rawResultView(_ text: String) -> some View {
        if tool.status != .failed {
            if presentation.category == .search {
                SearchResultsView(text: text)
            } else {
                TextOutputBox(text: text, ansi: false)
            }
        }
    }

    private var hasTerminalContent: Bool {
        tool.content.contains { if case .terminal = $0 { return true } else { return false } }
    }

    /// 终端内容已有对应的会话在渲染(此时输出由终端视图负责,不再重复显示 `rawOutput` 文本)。
    private var showsTerminalSession: Bool {
        tool.content.contains { if case .terminal(let id) = $0 { return model.terminals[id] != nil } else { return false } }
    }

    private var hasDiffContent: Bool {
        tool.content.contains { if case .diff = $0 { return true } else { return false } }
    }

    private var fallbackDiff: (path: String, oldText: String?, newText: String)? {
        let path = presentation.subjectIsPath ? presentation.subject : (tool.locations.first?.path ?? "")
        if let input = tool.rawInput {
            let oldText = input["old_string"]?.stringValue
                ?? input["oldText"]?.stringValue
                ?? input["TargetContent"]?.stringValue
            let newText = input["new_string"]?.stringValue
                ?? input["newText"]?.stringValue
                ?? input["ReplacementContent"]?.stringValue
                ?? input["CodeContent"]?.stringValue
                ?? input["content"]?.stringValue
            if let newText {
                return (path: path, oldText: oldText, newText: newText)
            }
        }
        if !path.isEmpty, let change = model.turnChange(at: path) {
            return (path: path, oldText: change.original, newText: change.current)
        }
        return nil
    }

    /// 文本类内容拼接。
    private var plainOutput: String {
        tool.content.compactMap { content -> String? in
            if case .content(let block) = content { return block.plainText }
            return nil
        }.joined(separator: "\n")
    }

    @ViewBuilder
    private func contentView(_ content: ToolCallContent) -> some View {
        switch content {
        case .diff(let path, let oldText, let newText):
            SnippetDiffView(path: path, oldText: oldText, newText: newText, showHeader: false)
        case .terminal(let id):
            if let session = model.terminals[id] {
                TerminalOutputView(session: session, onInterrupt: session.isExternal ? nil : { model.interruptTerminal(id) }, onRetryUnsandboxed: { model.retryWithoutSandbox() },
                                   onViewInTerminal: { AppActions.shared.viewAgentTerminal(session, model: model) })
            } else {
                Label(String(localized: "终端 \(id)"), om: "terminal").font(OMFonts.monoSmall)
            }
        case .content(let block):
            if case .image(let data, let mimeType, _) = block {
                ToolImageView(base64: data, mimeType: mimeType)
            } else if let text = block.plainText, !text.isEmpty {
                switch presentation.category {
                case .search:
                    SearchResultsView(text: text)
                case .terminal:
                    if hasTerminalContent { TextOutputBox(text: text) } else { EmptyView() }
                default:
                    TextOutputBox(text: text, ansi: false)
                }
            }
        case .unknown:
            EmptyView()
        }
    }
}

/// 文本输出框:长输出限高滚动,可展开(见 `CollapsibleOutput`)。
struct TextOutputBox: View {
    let text: String
    var ansi = true

    var body: some View {
        CollapsibleOutput(raw: ToolOutputText.stripFence(text), ansi: ansi)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
    }
}

/// 失败原因框:工具失败时展示 Agent 回传的错误文本(危险色,可选中复制)。
struct ToolErrorBox: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image.om("circle-alert", size: 11).foregroundStyle(OMColors.danger)
            Text(verbatim: text)
                .font(OMFonts.monoSmall)
                .foregroundStyle(OMColors.danger)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        .accessibilityLabel(String(localized: "失败原因:\(text)"))
    }
}

/// 命令框:`$ command` + 输出 + 复制(Agent 自带终端之外的命令执行)。
struct CommandBox: View {
    let command: String
    let output: String
    let status: ToolStatus
    var exitCode: Int?
    let copyText: String
    @State private var copied = false
    @State private var commandExpanded = false
    /// 命令超过该行数时默认折叠
    private static let commandLineLimit = 6

    var body: some View {
        let cleaned = ToolOutputText.stripFence(output)
        let commandLines = command.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").font(OMFonts.monoSmall).foregroundStyle(OMColors.tertiaryText)
                ShellCommandText(command: command, lineLimit: commandExpanded ? nil : Self.commandLineLimit)
                Spacer(minLength: 8)
                if let exitCode, exitCode != 0 {
                    OMTag(String(localized: "退出 \(exitCode)"), tint: OMColors.danger)
                }
                if commandLines > Self.commandLineLimit {
                    Button { omWithAnimation(.snappy(duration: 0.2)) { commandExpanded.toggle() } } label: {
                        Image.om(commandExpanded ? "chevrons-down-up" : "chevrons-up-down", size: 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OMColors.secondaryText)
                    .omTooltip(commandExpanded ? String(localized: "收起命令") : String(localized: "展开完整命令"))
                    .accessibilityLabel(commandExpanded ? String(localized: "收起命令") : String(localized: "展开完整命令"))
                }
                CopyButton(text: copyText, copied: $copied)
            }
            if !cleaned.isEmpty {
                CollapsibleOutput(raw: cleaned, followTail: status == .inProgress,
                                  tint: status == .failed ? OMColors.danger : OMColors.secondaryText)
            }
        }
        .padding(8)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
    }
}

/// 复制按钮:点击后短暂显示“已复制”。
struct CopyButton: View {
    let text: String
    @Binding var copied: Bool

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image.om(copied ? "check" : "copy", size: 11)
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .omTooltip(copied ? String(localized: "已复制") : String(localized: "复制"))
        .accessibilityLabel(copied ? String(localized: "已复制") : String(localized: "复制"))
    }
}

/// 键值对(MCP 入参)。
struct KeyValueBox: View {
    let title: String
    let value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            if let object = value.objectValue {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(object.keys.sorted(), id: \.self) { key in
                        GridRow {
                            Text(key).foregroundStyle(OMColors.secondaryText)
                            Text(object[key]?.stringValue ?? object[key]?.compactDescription ?? "")
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(OMFonts.monoSmall)
            } else {
                Text(value.compactDescription).font(OMFonts.monoSmall).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
    }
}

// MARK: - 搜索结果

/// 搜索结果列表:路径 + 行号 + 命中行,点击在工作台打开并定位。
struct SearchResultsView: View {
    let text: String
    @Environment(SessionModel.self) private var model
    @State private var showAll = false
    private let initialCount = 8

    var body: some View {
        let hits = SearchResultParser.parse(text)
        if hits.isEmpty {
            TextOutputBox(text: text, ansi: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? hits : Array(hits.prefix(initialCount))) { hit in
                    SearchHitRow(hit: hit) {
                        model.viewerRequest = FileViewRequest(path: resolveToolPath(hit.path, workspace: model.workspace.path), line: hit.line)
                    }
                }
                if hits.count > initialCount {
                    Button(showAll ? String(localized: "收起") : String(localized: "显示全部 \(hits.count) 条")) { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(OMFonts.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 3)
            .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
        }
    }
}

/// 单条命中。
struct SearchHitRow: View {
    let hit: SearchHit
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                OMFileIcon(name: (hit.path as NSString).lastPathComponent, size: 13)
                Text((hit.path as NSString).lastPathComponent).font(OMFonts.small.weight(.medium))
                if let line = hit.line { Text(":\(line)").font(OMFonts.monoSmall).foregroundStyle(OMColors.tertiaryText) }
                if let text = hit.text, !text.isEmpty {
                    Text(text)
                        .font(OMFonts.monoSmall)
                        .foregroundStyle(OMColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? OMColors.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .omTooltip(hit.path)
        .accessibilityLabel("\(hit.path)\(hit.line.map { String(localized: " 第 \($0) 行") } ?? "")")
    }
}

// MARK: - 浏览分组

/// 对话流的展示单元分发:单个条目或浏览分组。
struct TimelineItemView: View, Equatable {
    let item: TimelineItem
    private let itemID: UUID
    private let signature: Int

    @MainActor
    init(item: TimelineItem) {
        self.item = item
        itemID = item.id
        signature = item.signature
    }

    /// 结构不变(身份与成员数量相同)就视为相等,避免父视图重新求值时重建所有行。
    nonisolated static func == (lhs: TimelineItemView, rhs: TimelineItemView) -> Bool {
        lhs.itemID == rhs.itemID && lhs.signature == rhs.signature
    }

    var body: some View {
        switch item {
        case .entry(let entry): TimelineEntryView(entry: entry)
        case .explore(let group): ExploreGroupView(group: group)
        case .digest(let digest): TurnDigestView(digest: digest)
        }
    }
}

/// 连续浏览步骤的折叠分组:默认折叠(运行中、失败时都不自动展开),由用户自行展开。
struct ExploreGroupView: View {
    let group: ExploreGroup
    @Environment(\.stickyUser) private var scrollState
    @State private var expanded: Bool?
    @State private var hovering = false
    /// 分组是否是进行中会话的最后一项:是则后面还会有下一步,「最新一步」行保持占位(工具之间不收起,界面不跳)
    @Environment(\.liveTail) private var liveTail

    /// 展开/收起分组(标题行与「最新一步」行共用),并暂停底部自动跟随。
    private func toggle() {
        scrollState?.followSuspended = true
        expanded = !(expanded ?? DebugFlags.expandAll)
    }

    var body: some View {
        let isExpanded = expanded ?? DebugFlags.expandAll
        VStack(alignment: .leading, spacing: 0) {
            // 贴合内容宽度的文字行(无底色长条):悬停时文字加深、箭头显现,点击区域只在文字与箭头上
            HStack(spacing: 7) {
                Image.om(group.style == .activity ? "layers" : "text.magnifyingglass", size: 11.5)
                    .frame(width: 16)
                    .foregroundStyle(OMColors.secondaryText)
                Text(group.summary)
                    .font(OMFonts.small)
                    .foregroundStyle(hovering || isExpanded ? OMColors.primaryText : OMColors.secondaryText)
                    .flowingText(group.isRunning)
                Image.om("chevron.right", size: 9, weight: .bold)
                    .foregroundStyle(OMColors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hovering || isExpanded ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(group.summary)
            .accessibilityAddTraits(.isButton)
            if !isExpanded && (group.isRunning || liveTail) {
                GroupLatestStepView(group: group, onTap: toggle)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.entries) { entry in
                        TimelineEntryView(entry: entry)
                    }
                }
                // 竖线对齐标题图标中心线(x≈16),子内容整体右移到线的右侧,避免子行箭头压在线上
                .padding(.leading, 28)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OMColors.hairline).frame(width: 1).padding(.leading, 15.5)
                }
                .transition(.opacity)
            }
        }
    }
}

/// 回合折叠行(对齐 Cursor 的「Worked for 1h 37m」):回合结束后整段过程折成「已工作 12分8秒」,点击原位展开。
struct TurnDigestView: View {
    let digest: TurnDigest
    @Environment(\.stickyUser) private var scrollState
    @AppStorage(ClientPrefs.Key.toolDensity) private var densityRaw = ToolDensity.standard.rawValue
    @State private var expanded: Bool?
    @State private var hovering = false

    var body: some View {
        let isExpanded = expanded ?? DebugFlags.expandAll
        VStack(alignment: .leading, spacing: 0) {
            // 纯文字样式(贴合内容宽度,无底色长条):悬停时文字加深、箭头显现;点击区域只在文字与箭头上
            HStack(spacing: 4) {
                Text("已工作 \(digest.durationText)")
                    .font(OMFonts.small)
                    .foregroundStyle(hovering || isExpanded ? OMColors.primaryText : OMColors.secondaryText)
                Image.om("chevron.right", size: 9, weight: .bold)
                    .foregroundStyle(OMColors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(hovering || isExpanded ? 1 : 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                scrollState?.followSuspended = true
                expanded = !isExpanded
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("已工作 \(digest.durationText)"))
            .accessibilityAddTraits(.isButton)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TimelineGrouping.group(digest.entries, density: ToolDensity(rawValue: densityRaw) ?? .standard)) { item in
                        TimelineItemView(item: item)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OMColors.hairline).frame(width: 1).padding(.leading, 3)
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - 终端输出

/// Agent 终端输出:命令行、ANSI 彩色输出、退出码、耗时、复制与中断。
struct TerminalOutputView: View {
    let session: TerminalSession
    var fillHeight = false
    var onInterrupt: (() -> Void)?
    /// 沙箱拦截后「放行一次」
    var onRetryUnsandboxed: (() -> Void)?
    /// 在终端面板里查看(只读,SwiftTerm 渲染)
    var onViewInTerminal: (() -> Void)?
    @AppStorage(ClientPrefs.Key.terminalFontSize) private var outputFontSize = 12.0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(OMColors.tertiaryText)
                ShellCommandText(command: session.command, lineLimit: 1)
                Spacer()
                if session.sandboxed { OMTag(String(localized: "沙箱"), tint: OMColors.secondaryText) }
                if session.isBackground { OMTag(String(localized: "后台"), tint: OMColors.secondaryText) }
                if session.isRunning {
                    OMSpinner(.mini)
                    if let onInterrupt {
                        Button("停止", action: onInterrupt)
                            .buttonStyle(.omSecondary)
                            .controlSize(.mini)
                    }
                } else if let code = session.exitCode {
                    OMTag(code == 0 ? String(localized: "退出 0") : String(localized: "退出 \(code)"), tint: code == 0 ? OMColors.success : OMColors.danger)
                } else if let signal = session.signal {
                    OMTag(signal, tint: OMColors.danger)
                }
                if let onViewInTerminal {
                    Button(action: onViewInTerminal) { Image.om("square-terminal", size: 12) }
                        .buttonStyle(.omIcon)
                        .omTooltip("在终端面板查看")
                        .accessibilityLabel("在终端面板查看")
                }
                CopyButton(text: ANSIParser.plainText(session.output), copied: $copied)
            }
            .font(OMFonts.monoSmall)
            .foregroundStyle(OMColors.secondaryText)
            ScrollViewReader { proxy in
                ScrollView {
                    ANSITextView(raw: session.output, fontSize: outputFontSize)
                        .id("tail")
                }
                .frame(maxHeight: fillHeight ? .infinity : 240)
                .onChange(of: session.output) { proxy.scrollTo("tail", anchor: .bottom) }
            }
            if session.sandboxBlocked, let onRetryUnsandboxed {
                HStack(spacing: 8) {
                    Text("命令可能被沙箱拦截(只允许写入工作区与临时目录)。").font(OMFonts.caption).foregroundStyle(OMColors.warning)
                    Button("放行一次并重试", action: onRetryUnsandboxed).buttonStyle(.omSecondary)
                }
            }
            if session.truncated {
                Text("输出过长,仅显示末尾部分").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
        .padding(10)
        .frame(maxHeight: fillHeight ? .infinity : nil, alignment: .top)
        .background(OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
    }
}
