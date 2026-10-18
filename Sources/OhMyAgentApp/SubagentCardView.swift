// @author ixxxxoooo
// 子代理卡片(对标 Cursor 子代理,无框):父对话里的主要观察窗口。
// 两行纯文字:第一行「类型图标 + 任务标题 + 类型名(灰)」,第二行是状态(启动中 / 运行中 / 已完成 …)与待办计数、
// 当前活动或用时统计;点击整块在标签页里打开子代理的完整对话。

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
            let presentation = ToolPresentation(tool: tool, hasChild: true)
            Button { open(tool) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image.om(SubagentIcon.symbol(for: presentation.agentType), size: 14)
                        .foregroundStyle(iconColor(status))
                        .frame(width: 16, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine(presentation, tool: tool)
                        statusLine(status)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .omTooltip("在标签页中打开子代理的完整对话")
            .accessibilityLabel("子代理:\(tool.title)")
            .accessibilityHint("在标签页中打开子代理的完整对话")
            .omContextMenu {
                OMMenuItem("在标签中打开子 Agent 会话", icon: "external-link") { open(tool) }
                OMMenuItem("查看子 Agent 定义…", icon: "bot") { AppActions.shared.openSettings(page: .subagents) }
            }
        }
    }

    /// 图标颜色:进行中强调色、失败危险色,其余次要色。
    private func iconColor(_ status: SubagentStatus) -> Color {
        if status.phase == .failed { return OMColors.danger }
        return status.isActive ? OMColors.accent : OMColors.secondaryText
    }

    /// 第一行:任务标题 + 灰色类型名,悬停时末尾出现「打开」图标。
    private func titleLine(_ p: ToolPresentation, tool: ToolCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: p.subject.isEmpty ? tool.title : p.subject)
                .font(OMFonts.body)
                .foregroundStyle(OMColors.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let type = p.agentType {
                Text(verbatim: type)
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
            }
            Image.om("square-arrow-out-up-right", size: 11)
                .foregroundStyle(OMColors.secondaryText)
                .opacity(hovering ? 1 : 0)
        }
    }

    /// 第二行:阶段文字 + 待办计数 + 当前活动(进行中)/ 用时与工具调用数(结束后)。
    private func statusLine(_ status: SubagentStatus) -> some View {
        HStack(spacing: 8) {
            phase(status)
            if status.todoTotal > 0 {
                Text("待办 \(status.todoDone)/\(status.todoTotal)")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
            }
            trailingText(status)
        }
        .font(OMFonts.small)
    }

    /// 阶段指示:进行中带转圈/圆点,已完成绿色对勾、已失败红色叉。
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
                Text("已完成").foregroundStyle(OMColors.success)
            case .failed:
                Image.om("circle-x", size: 12).foregroundStyle(OMColors.danger)
                Text("已失败").foregroundStyle(OMColors.danger)
            }
        }
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
