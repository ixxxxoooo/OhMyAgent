// @author ygw
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
    @State private var expanded: Bool?
    @State private var hovering = false
    @State private var stats: DiffStats?

    /// 新增/删除行统计。
    struct DiffStats: Equatable { var added: Int; var removed: Int }

    var body: some View {
        if let tool = entry.tool {
            let presentation = ToolPresentation(tool: tool, hasChild: entry.childStore != nil)
            let canExpand = hasDetails(tool, presentation)
            let isExpanded = canExpand && (expanded ?? defaultExpanded(tool, presentation))
            VStack(alignment: .leading, spacing: 0) {
                row(tool, presentation, canExpand: canExpand, isExpanded: isExpanded)
                if isExpanded {
                    ToolDetailsView(entry: entry, tool: tool, presentation: presentation)
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

    // MARK: 行

    private func row(_ tool: ToolCall, _ p: ToolPresentation, canExpand: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: 7) {
            Image.om(ToolIcons.symbol(for: p.category), size: 11.5)
                .frame(width: 16)
                .foregroundStyle(tool.status == .failed ? Color.red : OMColors.secondaryText)
            if let server = p.mcpServer { OMTag(server, tint: OMColors.accent) }
            if let agentType = p.agentType { OMTag(agentType, tint: OMColors.accent) }
            if !p.verb.isEmpty {
                Text(p.verb)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
            }
            subject(p, failed: tool.status == .failed)
            if let detail = p.detail, !detail.isEmpty {
                Text(detail)
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering, let path = openablePath(tool, p) {
                Button {
                    model.viewerRequest = FileViewRequest(path: path, line: tool.locations.first?.line)
                } label: {
                    Image.om("arrow.up.right.square", size: 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .help("打开文件")
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
                .help("在标签中打开子 Agent 会话")
                .accessibilityLabel("在标签中打开子 Agent 会话")
            }
            if let stats, stats.added + stats.removed > 0 {
                HStack(spacing: 4) {
                    if stats.added > 0 { Text("+\(stats.added)").foregroundStyle(OMColors.diffAdded) }
                    if stats.removed > 0 { Text("−\(stats.removed)").foregroundStyle(OMColors.diffRemoved) }
                }
                .font(OMFonts.monoSmall)
            }
            if p.category == .terminal { durationText(tool) }
            statusView(tool.status)
            if canExpand {
                Image.om("chevron.right", size: 9, weight: .bold)
                    .foregroundStyle(OMColors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering && canExpand ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard canExpand else { return }
            omWithAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.plainText),\(Self.statusText(tool.status))")
        .accessibilityAddTraits(canExpand ? .isButton : [])
        .contextMenu {
            if p.category == .subagent {
                if entry.childStore != nil {
                    Button("在标签中打开子 Agent 会话") {
                        let workbench = AppEnvironment.shared.workbench
                        if let project = workbench.projectID(of: model) {
                            workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
                        }
                    }
                }
                Button("查看子 Agent 定义…") { AppActions.shared.openSettings(page: .tools, section: .agents) }
            }
        }
    }

    @ViewBuilder
    private func subject(_ p: ToolPresentation, failed: Bool) -> some View {
        if p.subjectIsPath {
            let name = (p.subject as NSString).lastPathComponent
            let dir = ((p.subject as NSString).deletingLastPathComponent as NSString).lastPathComponent
            HStack(spacing: 5) {
                Text(name)
                    .font(OMFonts.small.weight(.medium))
                    .foregroundStyle(failed ? Color.red : Color.primary)
                if !dir.isEmpty, dir != "/" {
                    Text(dir).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                }
            }
            .lineLimit(1)
            .help(p.subject)
        } else if p.category == .terminal || p.category == .search {
            Text(p.subject)
                .font(OMFonts.monoSmall)
                .foregroundStyle(failed ? Color.red : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(p.subject)
                .font(OMFonts.small.weight(.medium))
                .foregroundStyle(failed ? Color.red : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func durationText(_ tool: ToolCall) -> some View {
        if tool.status.isTerminal {
            Text(Self.format(entry.elapsedSeconds))
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
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
        case .inProgress: ProgressView().controlSize(.mini)
        case .completed: Image.om("checkmark", size: 9, weight: .bold).foregroundStyle(.green.opacity(0.8))
        case .failed: Image.om("xmark", size: 9, weight: .bold).foregroundStyle(.red)
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
        if !tool.content.isEmpty || entry.childStore != nil { return true }
        if p.category == .mcp, tool.rawInput != nil { return true }
        if p.category == .terminal, let command = tool.rawInput?["command"]?.stringValue, command.contains("\n") || command.count > 80 { return true }
        return false
    }

    /// 默认展开:有 Diff、失败、运行中的终端、运行中的子 Agent。
    private func defaultExpanded(_ tool: ToolCall, _ p: ToolPresentation) -> Bool {
        if DebugFlags.expandAll || tool.status == .failed { return true }
        if entry.childStore != nil, !tool.status.isTerminal { return true }
        for content in tool.content {
            switch content {
            case .diff: return true
            case .terminal(let id): if model.terminals[id]?.isRunning ?? false { return true }
            default: continue
            }
        }
        return false
    }

    static func statusText(_ status: ToolStatus) -> String {
        switch status {
        case .pending: return "等待中"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    /// 耗时格式:<10 秒保留一位小数。
    static func format(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1f 秒", seconds) }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        return "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒"
    }
}

// MARK: - 详情

/// 工具详情:按类别渲染内容。
struct ToolDetailsView: View {
    let entry: TimelineEntry
    let tool: ToolCall
    let presentation: ToolPresentation
    @Environment(SessionModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if presentation.category == .mcp, let input = tool.rawInput {
                KeyValueBox(title: "入参", value: input)
            }
            if presentation.category == .terminal, !hasTerminalContent,
               let command = tool.rawInput?["command"]?.stringValue {
                CommandBox(command: command, output: plainOutput, status: tool.status, copyText: command + (plainOutput.isEmpty ? "" : "\n" + plainOutput))
            }
            ForEach(Array(tool.content.enumerated()), id: \.offset) { _, content in
                contentView(content)
            }
            if let child = entry.childStore, !child.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TimelineGrouping.group(child.entries)) { item in
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

    private var hasTerminalContent: Bool {
        tool.content.contains { if case .terminal = $0 { return true } else { return false } }
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
                TerminalOutputView(session: session) { model.interruptTerminal(id) }
            } else {
                Label("终端 \(id)", om: "terminal").font(OMFonts.monoSmall)
            }
        case .content(let block):
            if let text = block.plainText, !text.isEmpty {
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

/// 可折叠的文本输出框。
struct TextOutputBox: View {
    let text: String
    var ansi = true
    var lineLimit = 14
    @State private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let clipped = !showAll && lines.count > lineLimit
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if ansi {
                    ANSITextView(raw: clipped ? lines.prefix(lineLimit).joined(separator: "\n") : text)
                } else {
                    Text(clipped ? lines.prefix(lineLimit).joined(separator: "\n") : text)
                        .font(OMFonts.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if lines.count > lineLimit {
                Button(showAll ? "收起" : "显示全部 \(lines.count) 行") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(OMFonts.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 命令框:`$ command` + 输出 + 复制(Agent 自带终端之外的命令执行)。
struct CommandBox: View {
    let command: String
    let output: String
    let status: ToolStatus
    let copyText: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").foregroundStyle(OMColors.tertiaryText)
                Text(command).textSelection(.enabled)
                Spacer(minLength: 8)
                CopyButton(text: copyText, copied: $copied)
            }
            .font(OMFonts.monoSmall)
            if !output.isEmpty {
                ANSITextView(raw: output)
                    .foregroundStyle(status == .failed ? Color.red : Color.primary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            Image.om(copied ? "checkmark" : "doc.on.doc", size: 11)
        }
        .buttonStyle(.plain)
        .foregroundStyle(OMColors.secondaryText)
        .help(copied ? "已复制" : "复制")
        .accessibilityLabel(copied ? "已复制" : "复制")
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
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                    Button(showAll ? "收起" : "显示全部 \(hits.count) 条") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(OMFonts.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                Image.om("doc.text", size: 10.5).foregroundStyle(OMColors.secondaryText)
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
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hit.path)
        .accessibilityLabel("\(hit.path)\(hit.line.map { " 第 \($0) 行" } ?? "")")
    }
}

// MARK: - 浏览分组

/// 对话流的展示单元分发:单个条目或浏览分组。
struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item {
        case .entry(let entry): TimelineEntryView(entry: entry)
        case .explore(let group): ExploreGroupView(group: group)
        }
    }
}

/// 连续浏览步骤的折叠分组:运行中展开,结束后自动折叠(失败时保持展开)。
struct ExploreGroupView: View {
    let group: ExploreGroup
    @State private var expanded: Bool?
    @State private var hovering = false

    var body: some View {
        let isExpanded = expanded ?? (DebugFlags.expandAll || group.isRunning || group.hasFailure)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image.om("text.magnifyingglass", size: 11.5)
                    .frame(width: 16)
                    .foregroundStyle(OMColors.secondaryText)
                Text(group.summary)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                if group.isRunning { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                Image.om("chevron.right", size: 9, weight: .bold)
                    .foregroundStyle(OMColors.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { omWithAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(group.summary)
            .accessibilityAddTraits(.isButton)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.entries) { entry in
                        TimelineEntryView(entry: entry)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(OMColors.hairline).frame(width: 1.5).padding(.leading, 15)
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
    var onInterrupt: (() -> Void)?
    @AppStorage(ClientPrefs.Key.terminalFontSize) private var outputFontSize = 11.5
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("$").foregroundStyle(OMColors.tertiaryText)
                Text(session.command).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if session.isRunning {
                    ProgressView().controlSize(.mini)
                    if let onInterrupt {
                        Button("停止", action: onInterrupt)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                } else if let code = session.exitCode {
                    OMTag(code == 0 ? "退出 0" : "退出 \(code)", tint: code == 0 ? .green : .red)
                } else if let signal = session.signal {
                    OMTag(signal, tint: .red)
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
                .frame(maxHeight: 240)
                .onChange(of: session.output) { proxy.scrollTo("tail", anchor: .bottom) }
            }
            if session.truncated {
                Text("输出过长,仅显示末尾部分").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
