// @author ixxxxoooo
// 子 Agent 标签页:顶部是主代理发来的任务,中间是子 Agent 的回答(与主会话同一套渲染),底部是状态与统计。

import ACPKit
import ChatKit
import DesignSystem
import DiffKit
import EditorKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 子 Agent 标签:只读展示子 Agent 的完整会话(含内部工具行、分组与实时状态)。
struct SubagentTabView: View {
    let workbench: WorkbenchModel
    let projectID: String
    let toolCallID: String
    @AppStorage(ClientPrefs.Key.chatWidth) private var chatWidth = ChatWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var chatWidthCustom = ChatWidth.customDefault
    @AppStorage(ClientPrefs.Key.toolDensity) private var toolDensityRaw = ToolDensity.standard.rawValue

    var body: some View {
        if let model = workbench.sessions[projectID],
           let entry = model.timeline.toolEntry(id: toolCallID), let tool = entry.tool {
            VStack(spacing: 0) {
                header(tool: tool, entry: entry)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // 顶部:主代理带给子代理的任务(输入);下面是子代理的回答,与主会话同一套渲染
                        if let prompt = tool.rawInput?["prompt"]?.stringValue, !prompt.isEmpty {
                            SubagentPromptCard(prompt: prompt)
                        }
                        if let child = entry.childStore, !child.entries.isEmpty {
                            ForEach(TimelineGrouping.group(child.entries, density: ToolDensity(rawValue: toolDensityRaw) ?? .standard)) { item in
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
            let agentType = ToolPresentation(tool: tool, hasChild: true).agentType
            Image.om(SubagentIcon.symbol(for: agentType), size: 14).foregroundStyle(OMColors.accent)
            Text(tool.title).font(OMFonts.body.weight(.medium)).lineLimit(1)
            if let agentType { Text(verbatim: agentType).font(OMFonts.small).foregroundStyle(OMColors.tertiaryText) }
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

/// 子 Agent 标签顶部的「主代理发送」卡片:主代理交给子代理的任务原文,长文折叠(沿用输入区卡片样式)。
struct SubagentPromptCard: View {
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("主代理发送的任务", om: "send")
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.tertiaryText)
                .labelStyle(.titleAndIcon)
            CollapsibleUserText(text: prompt)
                .foregroundStyle(OMColors.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .padding(.bottom, 6)
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
