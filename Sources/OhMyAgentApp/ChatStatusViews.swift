// @author ygw
// 输入区上方的状态卡片:`/goal` 目标条、排队消息面板、后台子 Agent 面板。

import ACPKit
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

/// 输入栏上方的「后台子 Agent」面板(参考 kuku / Cursor):
/// 只列运行中的子 Agent,全部结束后整块消失;点标题折叠/展开(按会话保存);
/// 每行显示 类型 · 最近工具 · 已运行时长,悬停出现「打开」;标题处可停止本轮。
struct SubagentActivityStrip: View {
    let model: SessionModel
    let workbench: WorkbenchModel

    var body: some View {
        let running = model.timeline.subagentEntries().filter { $0.entry.tool.map { !$0.status.isTerminal } ?? false }
        if !running.isEmpty {
            let collapsed = model.backgroundPanelCollapsed
            VStack(alignment: .leading, spacing: 0) {
                header(count: running.count, collapsed: collapsed)
                if !collapsed {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(running, id: \.entry.id) { item in
                                    SubagentRow(entry: item.entry, depth: item.depth, model: model, workbench: workbench)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 196)
                    }
                    .transition(.opacity)
                }
            }
            .omSolidCard()
            .accessibilityElement(children: .contain)
        }
    }

    private func header(count: Int, collapsed: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                omWithAnimation(.snappy(duration: 0.18)) { model.backgroundPanelCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image.om("chevron-down", size: 11, weight: .bold)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text("\(count) 个后台子 Agent")
                        .font(OMFonts.small)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(OMColors.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "展开后台子 Agent" : "收起后台子 Agent")
            Button("停止本轮") { model.cancel() }
                .buttonStyle(.plain)
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
                .padding(.horizontal, 10)
                .help("停止本轮(含所有子 Agent)")
        }
    }
}

/// 面板中的一行子 Agent。
private struct SubagentRow: View {
    let entry: TimelineEntry
    let depth: Int
    let model: SessionModel
    let workbench: WorkbenchModel
    @State private var hovering = false

    var body: some View {
        if let tool = entry.tool {
            let presentation = ToolPresentation(tool: tool, hasChild: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(presentation.subject)
                    .font(OMFonts.small)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let meta = meta(presentation) {
                    Text(meta)
                        .font(OMFonts.monoSmall)
                        .foregroundStyle(OMColors.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Button {
                    open(tool)
                } label: {
                    Image.om("square-arrow-out-up-right", size: 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .opacity(hovering ? 1 : 0)
                .help("在标签中打开子 Agent 会话")
                .accessibilityLabel("打开子 Agent 会话")
            }
            .padding(.leading, CGFloat(6 + depth * 12))
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { open(tool) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(presentation.subject)
        }
    }

    /// 灰色元信息:子 Agent 类型 · 最近工具 · 已运行时长。
    private func meta(_ presentation: ToolPresentation) -> String? {
        var parts: [String] = []
        if let type = presentation.agentType { parts.append(type) }
        if let last = entry.childStore?.entries.last(where: { $0.kind == .tool })?.tool?.title, !last.isEmpty {
            parts.append(last)
        }
        parts.append(WorkingStatus.elapsed(Int(entry.elapsedSeconds)))
        return parts.joined(separator: " · ")
    }

    private func open(_ tool: ToolCall) {
        guard let project = workbench.projectID(of: model) else { return }
        workbench.openSubagent(project: project, toolCallID: tool.toolCallId, title: tool.title)
    }
}
