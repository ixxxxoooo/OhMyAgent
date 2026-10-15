// @author ygw
// 输入区上方的状态卡片:`/goal` 目标条、排队消息面板、运行中的子 Agent 条。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// `/goal` 目标条:显示当前目标与状态,可清除。
struct GoalChip: View {
    let model: SessionModel

    var body: some View {
        if let goal = model.goal {
            HStack(spacing: 8) {
                Image.om("target", size: 12)
                    .foregroundStyle(goal.isActive ? OMColors.accent : OMColors.secondaryText)
                Text(goal.objective)
                    .font(OMFonts.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(goal.isActive ? "进行中" : "已结束")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 4)
                Button { model.clearGoal() } label: {
                    Image.om("x", size: 11).foregroundStyle(OMColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("清除目标")
                .accessibilityLabel("清除目标")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .omSolidCard()
            .help(goal.objective)
        }
    }
}

/// 排队消息面板:本轮结束后依次发送,可删除或立即发送(引导进当前轮次)。
struct FollowUpQueueView: View {
    let model: SessionModel

    var body: some View {
        if !model.followUps.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image.om("hourglass", size: 11)
                    Text("排队 \(model.followUps.count) 条,本轮结束后发送")
                        .font(OMFonts.small.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                ForEach(model.followUps) { item in
                    HStack(spacing: 8) {
                        if !item.images.isEmpty {
                            Label("\(item.images.count)", om: "image").font(OMFonts.caption)
                                .foregroundStyle(OMColors.secondaryText)
                        }
                        Text(item.text)
                            .font(OMFonts.small)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.sendFollowUpNow(item.id) } label: {
                            Image.om(model.isRunning && !model.canSteer ? "send-horizontal" : "corner-down-right", size: 11)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning && !model.canSteer)
                        .help(model.isRunning ? "立即引导进当前轮次" : "立即发送")
                        .accessibilityLabel("立即发送排队消息")
                        Button { model.removeFollowUp(item.id) } label: {
                            Image.om("x", size: 11)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                        .accessibilityLabel("移除排队消息")
                    }
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 4)
            .omSolidCard()
        }
    }
}

/// 运行中的子 Agent 条:列出正在执行的子任务,可点击打开其会话,或停止本轮。
struct SubagentActivityStrip: View {
    let model: SessionModel
    let workbench: WorkbenchModel

    var body: some View {
        let running = model.timeline.subagentEntries().filter { $0.entry.tool.map { !$0.status.isTerminal } ?? false }
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image.om("bot", size: 11)
                    Text("子 Agent 运行中 \(running.count)")
                        .font(OMFonts.small.weight(.medium))
                    Spacer()
                    Button("停止") { model.cancel() }
                        .buttonStyle(.plain)
                        .font(OMFonts.small)
                        .help("停止本轮(含所有子 Agent)")
                }
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                ForEach(Array(running.prefix(4).enumerated()), id: \.element.entry.id) { _, item in
                    if let tool = item.entry.tool {
                        let presentation = ToolPresentation(tool: tool, hasChild: true)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            if let type = presentation.agentType { OMTag(type, tint: OMColors.accent) }
                            Text(presentation.subject).font(OMFonts.small).lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                if let project = workbench.projectID(of: model) {
                                    workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
                                }
                            } label: {
                                Image.om("square-arrow-out-up-right", size: 11)
                            }
                            .buttonStyle(.plain)
                            .help("在标签中打开子 Agent 会话")
                            .accessibilityLabel("打开子 Agent 会话")
                        }
                        .foregroundStyle(OMColors.secondaryText)
                        .padding(.leading, CGFloat(12 + item.depth * 12))
                        .padding(.trailing, 12)
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.bottom, 4)
            .omSolidCard()
        }
    }
}
