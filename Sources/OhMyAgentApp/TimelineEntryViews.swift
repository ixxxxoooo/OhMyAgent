// @author ygw
// 时间线条目视图:用户、助手(Markdown)、思维面板、工具卡片、计划、提示。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 按类别分发条目视图。
struct TimelineEntryView: View {
    let entry: TimelineEntry

    var body: some View {
        switch entry.kind {
        case .user: UserMessageView(entry: entry)
        case .assistant: AssistantMessageView(entry: entry)
        case .thought: ThoughtView(entry: entry)
        case .tool: ToolCardView(entry: entry)
        case .plan: PlanView(entry: entry)
        case .notice: NoticeView(entry: entry)
        }
    }
}

/// 用户消息:纯色卡片。
struct UserMessageView: View {
    let entry: TimelineEntry

    var body: some View {
        Text(entry.text)
            .font(OMFonts.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .omSolidCard()
            .accessibilityLabel("你:\(entry.text)")
    }
}

/// 助手消息:Markdown 渲染。
struct AssistantMessageView: View {
    let entry: TimelineEntry

    var body: some View {
        MarkdownView(text: entry.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// 思维面板:流式时展开并计时,结束后自动折叠。
struct ThoughtView: View {
    let entry: TimelineEntry
    @State private var expanded: Bool

    init(entry: TimelineEntry) {
        self.entry = entry
        _expanded = State(initialValue: entry.isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if entry.isStreaming {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("思考中… \(Int(entry.elapsedSeconds)) 秒")
                        }
                    } else {
                        Text("已思考 \(max(1, Int(entry.elapsedSeconds.rounded()))) 秒")
                    }
                }
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(entry.text)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: entry.isStreaming) { _, streaming in
            if !streaming { withAnimation(.snappy(duration: 0.25)) { expanded = false } }
        }
    }
}

/// 计划视图。
struct PlanView: View {
    let entry: TimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("计划", systemImage: "list.bullet.clipboard")
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
            ForEach(Array(entry.plan.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(item.status))
                        .foregroundStyle(item.status == "completed" ? Color.green : OMColors.secondaryText)
                        .frame(width: 14)
                    Text(item.content)
                        .font(OMFonts.body)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? OMColors.secondaryText : Color.primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }
}

/// 提示 / 错误。
struct NoticeView: View {
    let entry: TimelineEntry

    var body: some View {
        Label(entry.text, systemImage: entry.isError ? "exclamationmark.circle.fill" : "info.circle")
            .font(OMFonts.small)
            .foregroundStyle(entry.isError ? Color.red : OMColors.secondaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 基础工具卡片(M3 扩展为含 Diff、终端、位置跳转的完整卡片)。
struct ToolCardView: View {
    let entry: TimelineEntry
    @State private var expanded = false

    var body: some View {
        if let tool = entry.tool {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(for: tool.kind))
                            .frame(width: 16)
                            .foregroundStyle(OMColors.secondaryText)
                        Text(tool.title.isEmpty ? (tool.name ?? "工具调用") : tool.title)
                            .font(OMFonts.small.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        statusView(tool.status)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    Divider()
                    details(tool)
                        .padding(12)
                }
            }
            .omSolidCard(cornerRadius: 10)
        }
    }

    @ViewBuilder
    private func statusView(_ status: ToolStatus) -> some View {
        switch status {
        case .pending: OMStatusDot(.idle)
        case .inProgress: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func details(_ tool: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(tool.content.enumerated()), id: \.offset) { _, content in
                switch content {
                case .content(let block):
                    if let text = block.plainText {
                        Text(text).font(OMFonts.monoSmall).textSelection(.enabled)
                    }
                case .diff(let path, let oldText, let newText):
                    let added = newText.split(separator: "\n", omittingEmptySubsequences: false).count
                    let removed = oldText?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
                    Label("\(path)  +\(added) −\(removed)", systemImage: "doc.badge.plus")
                        .font(OMFonts.monoSmall)
                case .terminal(let id):
                    Label("终端 \(id)", systemImage: "terminal").font(OMFonts.monoSmall)
                case .unknown:
                    EmptyView()
                }
            }
            if tool.content.isEmpty, let input = tool.rawInput {
                Text(input.compactDescription).font(OMFonts.monoSmall).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func icon(for kind: ToolKind) -> String {
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
}

/// 权限请求卡片。
struct PermissionCard: View {
    let prompt: PermissionPrompt
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: ToolCardView.icon(for: prompt.kind)).foregroundStyle(OMColors.warning)
                Text("需要你的许可").font(OMFonts.small.weight(.semibold))
            }
            Text(prompt.title)
                .font(OMFonts.monoSmall)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ForEach(prompt.request.options) { option in
                    Button(option.name) { onChoose(option.optionId) }
                        .buttonStyle(.bordered)
                        .tint(option.kind == .allowOnce || option.kind == .allowAlways ? OMColors.accent : nil)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("权限请求:\(prompt.title)")
    }
}
