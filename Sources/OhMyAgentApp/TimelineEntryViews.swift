// @author ygw
// 时间线条目视图:用户、助手(Markdown)、思维面板、工具卡片、计划、提示。

import IconKit
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
        case .tool: ToolRowView(entry: entry)
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
                omWithAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image.om("chevron.right", size: 9, weight: .bold)
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
            if !streaming { omWithAnimation(.snappy(duration: 0.25)) { expanded = false } }
        }
    }
}

/// 计划视图。
struct PlanView: View {
    let entry: TimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("计划", om: "list.bullet.clipboard")
                .font(OMFonts.small.weight(.semibold))
                .foregroundStyle(OMColors.secondaryText)
            ForEach(Array(entry.plan.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image.om(icon(item.status))
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
        Label(entry.text, om: entry.isError ? "exclamationmark.circle.fill" : "info.circle")
            .font(OMFonts.small)
            .foregroundStyle(entry.isError ? Color.red : OMColors.secondaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 输入区上方的待办折叠卡:默认收起为一行「已完成 x / n」,点击展开完整计划。
struct PlanDock: View {
    let model: SessionModel
    @State private var expanded = false

    var body: some View {
        if let entry = model.timeline.entries.last(where: { $0.kind == .plan }), !entry.plan.isEmpty {
            let done = entry.plan.filter { $0.status == "completed" }.count
            VStack(spacing: 0) {
                Button {
                    omWithAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image.om(expanded ? "chevron.down" : "chevron.right", size: 10)
                        Image.om("list-checks", size: 12)
                        Text("待办 \(done)/\(entry.plan.count)").font(OMFonts.small.weight(.medium))
                        Spacer()
                    }
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起待办" : "展开待办")
                if expanded {
                    PlanView(entry: entry).padding([.horizontal, .bottom], 4)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}
