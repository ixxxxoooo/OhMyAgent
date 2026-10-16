// @author ixxxxoooo
// 输入区上方的「上下文用量」面板(参考 Cursor Context Usage 与 kuku):
// 占用百分比、分段进度条与分类明细;打开时向 Agent 请求一次 `/context` 明细(不调用模型)。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 上下文用量面板。
struct ContextUsagePanel: View {
    let model: SessionModel
    let onClose: () -> Void

    /// 面板展示的用量:运行中无法刷新明细,退回 Agent 实时上报;否则优先 `/context` 明细。
    private var display: ContextUsage? {
        let reported = model.usage.flatMap { ContextUsage(reported: $0) }
        return model.isRunning ? (reported ?? model.contextUsage) : (model.contextUsage ?? reported)
    }

    /// 是否只有「已用 / 剩余」两段合成数据(没有真实分类)。
    private var isSynthetic: Bool { model.contextUsage == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let usage = display {
                ContextUsageBody(usage: usage)
                hintRows(for: usage)
                footnotes(isSynthetic: isSynthetic)
            } else {
                Text(model.isProbingContext ? LocalizedStringKey("正在读取上下文明细…") : LocalizedStringKey("该 Agent 暂未上报上下文用量,发送消息后将显示。"))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.vertical, 10)
            }
            costRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
        .task(id: RefreshKey(sessionId: model.sessionId, running: model.isRunning)) {
            // 打开、换会话、回合结束时各刷新一次明细(回合进行中 refresh 会自行跳过)
            await model.refreshContextUsage()
        }
    }

    /// 触发明细刷新的条件:会话变化或运行状态变化。
    private struct RefreshKey: Equatable {
        let sessionId: String?
        let running: Bool
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("上下文用量").font(OMFonts.small.weight(.semibold))
            if model.isProbingContext { ProgressView().controlSize(.mini) }
            Spacer()
            Button(action: onClose) {
                Image.om("x", size: 11).foregroundStyle(OMColors.secondaryText).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭")
        }
    }

    /// 优化建议:MCP 工具定义占用偏高时提示开启按需加载;接近上限时提示压缩。
    @ViewBuilder
    private func hintRows(for usage: ContextUsage) -> some View {
        let hints = ContextAdvisor.hints(for: usage)
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hints, id: \.self) { hint in
                    switch hint {
                    case .mcpHeavy(let percent):
                        HStack(alignment: .top, spacing: 6) {
                            Image.om("sparkles", size: 12).foregroundStyle(OMColors.accent).padding(.top, 1)
                            Text("MCP 工具定义占用了约 \(percent)% 的上下文。可在「高级」里开启 MCP 工具按需加载,或停用不常用的 MCP 服务器。")
                                .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("去设置") { AppActions.shared.openSettings(page: .advanced) }
                                .buttonStyle(.plain).font(OMFonts.caption).foregroundStyle(OMColors.accent)
                                .accessibilityLabel(String(localized: "打开高级设置"))
                        }
                    case .nearFull(let percent):
                        HStack(alignment: .top, spacing: 6) {
                            Image.om("triangle-alert", size: 12).foregroundStyle(OMColors.warning).padding(.top, 1)
                            Text("上下文已用 \(percent)%,建议输入 /compact 压缩,或开启新会话。")
                                .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OMColors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
        }
    }

    @ViewBuilder
    private func footnotes(isSynthetic: Bool) -> some View {
        if isSynthetic && model.supportsContextBreakdown && !model.isRunning && !model.isProbingContext {
            Text("暂时无法读取分类明细,以下为 Agent 上报的总量。")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        } else if model.isRunning && model.supportsContextBreakdown {
            Text("回合进行中,分类明细将在结束后更新。")
                .font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
    }

    /// 累计费用与预算提醒(来自 Agent 上报,订阅账号可能没有)。
    @ViewBuilder
    private var costRow: some View {
        if let cost = model.usage?.costAmount {
            let budget = ClientPrefs.budgetUSD()
            HStack(spacing: 6) {
                Text("累计费用 \(cost.formatted(.number.precision(.fractionLength(2...4)))) \(model.usage?.costCurrency ?? "USD")")
                    .font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                if budget > 0, cost >= budget {
                    Label("已超过预算提醒阈值", om: "triangle-alert").font(OMFonts.caption).foregroundStyle(OMColors.warning)
                }
            }
        }
    }
}

/// 面板主体:占比标题、分段条与分类明细。
struct ContextUsageBody: View {
    let usage: ContextUsage

    var body: some View {
        let colored = usage.categories.enumerated().map { ContextPalette.Item(category: $1, color: ContextPalette.color(for: $1, index: $0)) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(usage.percent)% 已满").font(OMFonts.small.weight(.semibold))
                Spacer()
                Text("~\(ContextUsage.formatTokens(usage.totalTokens)) / \(ContextUsage.formatTokens(usage.maxTokens)) Tokens")
                    .font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
            }
            segmentBar(colored)
            VStack(spacing: 5) {
                ForEach(colored) { item in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(item.color).frame(width: 11, height: 11)
                        Text(item.category.name)
                            .font(OMFonts.small)
                            .foregroundStyle(item.category.kind == .free ? OMColors.secondaryText : Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ContextUsage.formatTokens(item.category.tokens))
                            .font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 分段条:已占用与压缩预留按 token 占窗口的比例分段,剩余留空。
    private func segmentBar(_ items: [ContextPalette.Item]) -> some View {
        let window = max(usage.maxTokens, 1)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(items.filter { $0.category.kind != .free }) { item in
                    Rectangle().fill(item.color)
                        .frame(width: max(0, proxy.size.width * CGFloat(item.category.tokens) / CGFloat(window)))
                        .help("\(item.category.name) · \(ContextUsage.formatTokens(item.category.tokens))")
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// 分类配色与 token 数格式化。
enum ContextPalette {
    /// 带颜色的分类行。
    struct Item: Identifiable {
        let category: ContextCategory
        let color: Color
        var id: String { category.id }
    }

    /// 已占用分类色板:灰、紫、绿、橙、洋红、蓝、绯红、红橙(循环)。
    private static let used: [Color] = [
        Color(red: 0.47, green: 0.47, blue: 0.47), Color(red: 0.48, green: 0.42, blue: 0.80),
        Color(red: 0.06, green: 0.48, blue: 0.31), Color(red: 0.69, green: 0.45, blue: 0.10),
        Color(red: 0.56, green: 0.10, blue: 0.43), Color(red: 0.18, green: 0.48, blue: 0.78),
        Color(red: 0.76, green: 0.12, blue: 0.34), Color(red: 0.78, green: 0.25, blue: 0.12),
    ]

    /// 取分类颜色:剩余用淡灰,压缩预留用冷灰,其余按序号取色板。
    static func color(for category: ContextCategory, index: Int) -> Color {
        switch category.kind {
        case .free: return Color.primary.opacity(0.14)
        case .buffer: return Color(red: 0.54, green: 0.58, blue: 0.64)
        case .used: return used[index % used.count]
        }
    }
}
