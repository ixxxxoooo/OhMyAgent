// @author ixxxxoooo
// 子代理卡片(对标 Cursor 子代理):父对话里的主要观察窗口——实时状态(启动中 → 运行中 → 已完成)、
// 待办计数、当前在做什么;点击整张卡片在标签页里打开子代理的完整对话。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

struct SubagentCardView: View {
    let entry: TimelineEntry
    @Environment(SessionModel.self) private var model
    @State private var hovering = false

    var body: some View {
        if let status = SubagentStatus.make(entry: entry), let tool = entry.tool {
            Button { open(tool) } label: {
                HStack(spacing: 10) {
                    phase(status)
                    if status.todoTotal > 0 {
                        Label("待办 \(status.todoDone)/\(status.todoTotal)", om: "list-checks")
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.secondaryText)
                            .labelStyle(.titleAndIcon)
                    }
                    trailingText(status)
                    Spacer(minLength: 8)
                    Image.om("square-arrow-out-up-right", size: 11)
                        .foregroundStyle(OMColors.secondaryText)
                        .opacity(hovering ? 1 : 0.55)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? OMColors.hoverFill : OMColors.subtleFill, in: RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous).strokeBorder(OMColors.hairline))
                .contentShape(RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .omTooltip("在标签页中打开子代理的完整对话")
            .accessibilityLabel("子代理:\(tool.title)")
            .accessibilityHint("在标签页中打开子代理的完整对话")
        }
    }

    /// 阶段指示:图标/转圈 + 文字。
    @ViewBuilder
    private func phase(_ status: SubagentStatus) -> some View {
        HStack(spacing: 6) {
            switch status.phase {
            case .starting:
                OMSpinner(.mini)
                Text("启动中").foregroundStyle(OMColors.secondaryText)
            case .running:
                OMSpinner(.mini)
                Text("运行中").foregroundStyle(OMColors.accentText)
            case .backgroundRunning:
                OMStatusDot(.running)
                Text("后台运行").foregroundStyle(OMColors.accentText)
            case .completed:
                Image.om("circle-check", size: 12).foregroundStyle(OMColors.success)
                Text("已完成").foregroundStyle(OMColors.secondaryText)
            case .failed:
                Image.om("circle-x", size: 12).foregroundStyle(OMColors.danger)
                Text("已失败").foregroundStyle(OMColors.danger)
            }
        }
        .font(OMFonts.small.weight(.medium))
    }

    /// 右侧文字:进行中显示当前活动;结束后显示用时与工具调用数。
    @ViewBuilder
    private func trailingText(_ status: SubagentStatus) -> some View {
        if status.isActive, let text = status.activityText {
            Text(verbatim: text)
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if !status.isActive, let summary = SubagentSummary.make(entry: entry) {
            Text(verbatim: summary.parts.joined(separator: " · "))
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func open(_ tool: ToolCall) {
        let workbench = AppEnvironment.shared.workbench
        if let project = workbench.projectID(of: model) {
            workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
        }
    }
}
