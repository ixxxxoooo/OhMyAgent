// @author ixxxxoooo
// 输入区上方的「上下文用量」面板(排版参考 BaoCode):
// 标题行「上下文窗口 已用 / 窗口 token · 百分比」→ 分段条 → 分类图例(横排换行)→ 提示缓存 → 套餐用量(每个限额一行)。
// 打开时向 Agent 请求一次 `/context` 明细(不调用模型),并主动获取一次套餐限额(`get_usage`,不调用模型)。

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
                ContextUsageBody(usage: usage, showsSummary: false)
                hintRows(for: usage)
                footnotes(isSynthetic: isSynthetic)
            } else {
                Text(model.isProbingContext ? LocalizedStringKey("正在读取上下文明细…") : LocalizedStringKey("该 Agent 暂未上报上下文用量,发送消息后将显示。"))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .padding(.vertical, 4)
            }
            if let cache = model.promptCache { PromptCacheRow(cache: cache) }
            PlanUsageSection(center: PlanUsageCenter.shared, cost: model.usage?.costAmount, currency: model.usage?.costCurrency)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omGlassCard()
        .accessibilityElement(children: .contain)
        .task(id: RefreshKey(sessionId: model.sessionId, running: model.isRunning, ready: model.phase == .ready && !model.isAttachingEngine)) {
            // 打开、换会话、引擎就绪、回合结束时各刷新一次明细(回合进行中 refresh 会自行跳过)
            await model.refreshContextUsage()
        }
        .task(id: model.sessionId) {
            // 套餐限额是账号级的,30 秒内重复打开直接复用
            await model.refreshPlanUsage()
        }
    }

    /// 触发明细刷新的条件:会话变化、运行状态变化或引擎就绪。
    /// 打开存档会话时先回显(已有 sessionId)再接回引擎,只看 sessionId 会错过就绪那一刻。
    private struct RefreshKey: Equatable {
        let sessionId: String?
        let running: Bool
        let ready: Bool
    }

    /// 标题行:「上下文窗口」+ 已用 / 窗口与百分比 + 关闭。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("上下文窗口").font(OMFonts.sectionTitle)
            if let usage = display {
                Text("\(ContextUsage.formatTokens(usage.totalTokens)) / \(ContextUsage.formatTokens(usage.maxTokens)) token · \(usage.percent)%")
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
            }
            // 已有数据时静默刷新,不再出现转圈(业界做法:先显示上次的值,后台更新)
            if model.isProbingContext && display == nil { OMSpinner(.mini) }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image.om("x", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .omTooltip("关闭")
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
            .background(OMColors.selectedFill, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
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
}

/// 面板主体:(可选)占比标题、分段条与横排图例。
struct ContextUsageBody: View {
    let usage: ContextUsage
    /// 是否显示「x% 已满 · 已用 / 窗口」标题(面板标题行已显示时关闭)
    var showsSummary = true

    var body: some View {
        let colored = usage.categories.enumerated().map { ContextPalette.Item(category: $1, color: ContextPalette.color(for: $1, index: $0)) }
        let used = colored.filter { $0.category.kind == .used && $0.category.tokens > 0 }
        let reserved = usage.categories.filter { $0.kind == .buffer }.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 10) {
            if showsSummary {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(usage.percent)% 已满").font(OMFonts.small.weight(.medium))
                    Spacer()
                    Text("~\(ContextUsage.formatTokens(usage.totalTokens)) / \(ContextUsage.formatTokens(usage.maxTokens)) Tokens")
                        .font(OMFonts.monoSmall).foregroundStyle(OMColors.secondaryText)
                }
            }
            UsageStrip(total: usage.maxTokens, parts: used.map { ($0.category.tokens, $0.color, "\($0.category.name) · \(ContextUsage.formatTokens($0.category.tokens))") }, height: 6)
            OMFlowLayout(spacing: 16, lineSpacing: 6) {
                ForEach(used) { item in
                    legend(color: item.color, label: item.category.name, tokens: item.category.tokens)
                }
                // 压缩预留不占分段条(是留空而非已用),只在图例里列出
                if reserved > 0 { legend(color: nil, label: String(localized: "为压缩预留"), tokens: reserved) }
            }
        }
    }

    /// 图例项:色块 + 名称 + 等宽数量。
    private func legend(color: Color?, label: String, tokens: Int) -> some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: OMRadius.tag).fill(color).frame(width: 9, height: 9) }
            Text(label).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1)
            Text(ContextUsage.formatTokens(tokens)).font(OMFonts.monoSmall).foregroundStyle(OMColors.primaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 一条圆角用量条:各部分按占总量的比例从左依次排列,剩余为轨道色;过小的部分至少 2pt 宽。
struct UsageStrip: View {
    /// 总量(条的全长)
    let total: Int
    /// 各部分:数量、颜色、悬浮提示(可为空)
    let parts: [(Int, Color, String)]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let whole = CGFloat(max(total, 1))
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let width = part.0 <= 0 ? 0 : min(max(2, proxy.size.width * CGFloat(part.0) / whole), proxy.size.width)
                    if part.2.isEmpty {
                        Rectangle().fill(part.1).frame(width: width)
                    } else {
                        Rectangle().fill(part.1).frame(width: width).omTooltip(part.2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .background(OMColors.pressedFill)
            .clipShape(Capsule()) // ui-lint:allow 进度条轨道为功能性胶囊
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 与限额行对齐的一行:左侧名称、中间用量条、右侧百分比与附注。
private struct MeterRow<Bar: View>: View {
    let label: String
    let percent: Int
    var percentColor: Color = OMColors.primaryText
    let note: String
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).lineLimit(1)
                .frame(width: 150, alignment: .leading)
            bar()
            Text("\(percent)%").font(OMFonts.monoSmall).foregroundStyle(percentColor)
                .frame(width: 48, alignment: .trailing)
            Text(note).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
                .frame(width: 120, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 提示缓存行:最近一轮输入被缓存读取的比例(读取 / 写入 / 未缓存三段),右侧为整段主对话的命中率;悬停看明细。
private struct PromptCacheRow: View {
    let cache: PromptCacheStats

    var body: some View {
        let last = cache.last
        let all = cache.conversation
        let format = ContextUsage.formatTokens
        MeterRow(label: String(localized: "提示缓存"), percent: last.hitPercent, note: String(localized: "主对话 \(all.hitPercent)%")) {
            UsageStrip(total: last.total, parts: [(last.read, OMColors.success, ""), (last.written, OMColors.warning, ""), (last.uncached, OMColors.danger, "")])
        }
        .omTooltip([
            String(localized: "最近一轮:读取 \(format(last.read)) · 写入 \(format(last.written)) · 未缓存 \(format(last.uncached))"),
            String(localized: "主对话:读取 \(format(all.read)) · 写入 \(format(all.written)) · 命中 \(all.hitPercent)%"),
            String(localized: "不含子 Agent、压缩及 CLI 的附带请求"),
        ].joined(separator: "\n"))
    }
}

/// 套餐用量:标题(右侧为本会话费用)与每个限额窗口一行;还没有数据时说明原因。
private struct PlanUsageSection: View {
    let center: PlanUsageCenter
    let cost: Double?
    let currency: String?

    /// 没有窗口时的说明。
    private var note: String? {
        guard center.windows.isEmpty else { return nil }
        switch center.state {
        case .checking: return String(localized: "正在获取额度…")
        case .unavailable: return String(localized: "暂时获取不到额度,稍后重新打开再试。")
        case .off: return String(localized: "额度随对话自动更新,对话后即可看到。")
        case .idle: return nil
        }
    }

    var body: some View {
        if !center.windows.isEmpty || note != nil || cost != nil {
            Rectangle().fill(OMColors.hairline).frame(height: 1).padding(.vertical, 2)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("套餐用量").font(OMFonts.sectionTitle)
                Spacer(minLength: 8)
                if let cost { costLabel(cost) }
            }
            // 每分钟刷新一次「多久后重置」
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(center.windows) { limitRow($0, now: context.date) }
                }
            }
            if let note { Text(note).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
        }
    }

    /// 本会话费用与预算提醒。
    private func costLabel(_ cost: Double) -> some View {
        let budget = ClientPrefs.budgetUSD()
        return HStack(spacing: 6) {
            if budget > 0, cost >= budget {
                Image.om("triangle-alert", size: 12).foregroundStyle(OMColors.warning)
                    .omTooltip("已超过预算提醒阈值")
                    .accessibilityLabel("已超过预算提醒阈值")
            }
            Text("本次会话").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            Text("\(cost.formatted(.number.precision(.fractionLength(2...4)))) \(currency ?? "USD")")
                .font(OMFonts.monoSmall).foregroundStyle(OMColors.primaryText)
        }
    }

    /// 一个限额窗口:≥70% 警示色,≥90% 危险色。
    private func limitRow(_ limit: RateLimitWindow, now: Date) -> some View {
        let fraction = limit.fraction(at: now)
        let color = fraction >= 0.9 ? OMColors.danger : fraction >= 0.7 ? OMColors.warning : OMColors.accent
        return MeterRow(label: limit.label, percent: Int((fraction * 100).rounded()), percentColor: fraction >= 0.9 ? color : OMColors.primaryText,
                        note: limit.resetsAt.flatMap { PlanResetText.text(until: $0, now: now) } ?? "") {
            UsageStrip(total: 1000, parts: [(Int((fraction * 1000).rounded()), color, "")])
        }
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

    /// 取分类颜色:剩余用淡灰,压缩预留用冷灰,其余按序号取色板。
    static func color(for category: ContextCategory, index: Int) -> Color {
        switch category.kind {
        case .free: return OMColors.pressedFill
        case .buffer: return OMColors.tertiaryText
        case .used: return OMColors.chart(index)
        }
    }
}
