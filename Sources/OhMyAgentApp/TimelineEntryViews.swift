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
        case .changes: ChangesSummaryView(entry: entry)
        }
    }
}

/// 用户消息:纯色卡片。
struct UserMessageView: View {
    let entry: TimelineEntry

    var body: some View {
        Text(entry.text)
            .font(OMFonts.reading)
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
                        .font(OMFonts.reading)
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
