// @author ixxxxoooo
// 设置页:用量与成本。登录与凭据完全由本机官方 claude 管理,客户端不提供账号 UI。
// 内容:概览指标卡、当前会话上下文分类、活动趋势图、每日 Token 图、按模型分析(Swift Charts)。
// 数据来自 claude 的统计缓存 `~/.claude/stats-cache.json`(只读)与当前会话的实时上报。

import ACPKit
import AgentHost
import AppKit
import Charts
import ChatKit
import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI

/// 活动图的指标。
private enum ActivityMetric: Hashable {
    case messages, sessions, toolCalls

    var title: String {
        switch self {
        case .messages: return "消息"
        case .sessions: return "会话"
        case .toolCalls: return "工具调用"
        }
    }

    func value(of day: DailyActivity) -> Int {
        switch self {
        case .messages: return day.messageCount
        case .sessions: return day.sessionCount
        case .toolCalls: return day.toolCallCount
        }
    }
}

/// 用量与成本。
struct UsagePage: View {
    let paths: ClaudePaths
    @AppStorage(ClientPrefs.Key.budgetUSD) private var budget = 0.0
    @State private var stats = UsageStatsSnapshot.empty
    @State private var rangeDays = 14
    @State private var metric = ActivityMetric.messages
    @State private var loaded = false

    /// 模型系列配色:取自主题令牌,按模型顺序循环。
    private var seriesColors: [Color] { [OMColors.accent, OMColors.accent2, OMColors.success, OMColors.warning, OMColors.danger] }

    var body: some View {
        SettingsForm {
            overviewSection
            currentSessionSection
            if !stats.daily.isEmpty {
                activitySection
                if !stats.dailyTokens.isEmpty { tokensSection }
            }
            if !stats.models.isEmpty { modelsSection }
            if loaded, stats.daily.isEmpty, stats.models.isEmpty {
                Section { EmptyHint(icon: "chart-column", title: String(localized: "没有找到统计数据"), message: String(localized: "claude 会定期把使用统计写入 ~/.claude/stats-cache.json,使用一段时间后这里会出现图表。")).frame(height: 160) }
            }
        }
        .task {
            stats = await Task.detached { UsageStats.load(paths: paths) }.value
            loaded = true
        }
    }

    // MARK: - 概览

    private var overviewSection: some View {
        Section {
            let week = stats.recent(days: 7)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                UsageTile(icon: "messages-square", title: String(localized: "近 7 天消息"), value: week.messages.formatted())
                UsageTile(icon: "layers", title: String(localized: "近 7 天会话"), value: week.sessions.formatted())
                UsageTile(icon: "wrench", title: String(localized: "近 7 天工具调用"), value: week.toolCalls.formatted())
                UsageTile(icon: "coins", title: String(localized: "累计 Token"), value: ContextUsage.formatTokens(stats.totalTokens))
                UsageTile(icon: "trending-up", title: String(localized: "累计费用"), value: stats.totalCostUSD > 0 ? "$" + stats.totalCostUSD.formatted(.number.precision(.fractionLength(2))) : "—")
                UsageTile(icon: "gauge", title: String(localized: "缓存命中率"), value: stats.cacheHitRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            }
            .padding(.vertical, 2)
            if let last = stats.lastComputedDate { Note("统计截止 \(last)(由 claude 定期更新)") }
        } header: {
            Label("概览", om: "chart-column")
        }
    }

    // MARK: - 当前会话

    private var currentSessionSection: some View {
        Section {
            if let model = AppEnvironment.shared.sessionModels.first, let usage = model.usage {
                let detail = model.contextUsage ?? ContextUsage(reported: usage)
                if let detail { ContextUsageBody(usage: detail).padding(.vertical, 4) }
                if let cost = usage.costAmount {
                    LabeledContent("累计费用", value: "\(cost.formatted(.number.precision(.fractionLength(2...4)))) \(usage.costCurrency ?? "USD")")
                    if budget > 0, cost >= budget { Label(String(localized: "已超过预算提醒阈值 \(budget.formatted()) USD"), om: "triangle-alert").foregroundStyle(OMColors.warning) }
                }
            } else {
                Text("当前没有用量数据").foregroundStyle(OMColors.secondaryText)
            }
            SettingsNumericField(title: "预算提醒", value: $budget, format: FloatingPointFormatStyle<Double>(), unit: "USD", prompt: "0 表示关闭")
            Note("预算提醒只在客户端侧判断:会话费用超过阈值时在用量弹层中高亮。订阅账号通常不上报费用。")
        } header: {
            Label("当前会话", om: "activity")
        }
    }

    // MARK: - 活动趋势

    private var activitySection: some View {
        Section {
            HStack {
                OMCompactSegmented(
                    options: [(ActivityMetric.messages, "消息"), (.sessions, "会话"), (.toolCalls, "工具调用")],
                    selection: $metric, accessibilityName: String(localized: "活动指标"))
                Spacer()
                OMCompactSegmented(
                    options: [(7, "7 天"), (14, "14 天"), (30, "30 天")],
                    selection: $rangeDays, accessibilityName: String(localized: "时间范围"))
            }
            let window = stats.dailyWindow(days: rangeDays)
            Chart(window) { day in
                BarMark(x: .value("日期", UsageStatsSnapshot.parseDay(day.date) ?? .distantPast, unit: .day),
                        y: .value(String(localized: String.LocalizationValue(metric.title)), metric.value(of: day)))
                    .foregroundStyle(OMColors.accent.gradient)
                    .cornerRadius(3)
            }
            .chartXAxis { dayAxis(count: window.count) }
            .frame(height: 160)
            .accessibilityLabel(String(localized: "活动趋势图"))
        } header: {
            Label("活动趋势", om: "chart-line")
        }
    }

    // MARK: - 每日 Token

    private var tokensSection: some View {
        Section {
            let window = stats.dailyTokenWindow(days: rangeDays)
            let names = modelNames(in: window)
            Chart {
                ForEach(window) { day in
                    ForEach(names, id: \.self) { name in
                        BarMark(x: .value("日期", UsageStatsSnapshot.parseDay(day.date) ?? .distantPast, unit: .day),
                                y: .value("Token", day.byModel[name] ?? 0))
                            .foregroundStyle(by: .value("模型", name))
                    }
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.indices.map { seriesColors[$0 % seriesColors.count] })
            .chartXAxis { dayAxis(count: window.count) }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(verbatim: ContextUsage.formatTokens(tokens)) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 190)
            .accessibilityLabel(String(localized: "每日 Token 图"))
        } header: {
            Label("每日 Token(按模型)", om: "chart-column")
        }
    }

    // MARK: - 按模型

    private var modelsSection: some View {
        Section {
            let top = Array(stats.models.prefix(8))
            Chart {
                ForEach(top) { item in
                    BarMark(x: .value("Token", item.inputTokens), y: .value("模型", item.model))
                        .foregroundStyle(by: .value("类型", String(localized: "输入")))
                    BarMark(x: .value("Token", item.outputTokens), y: .value("模型", item.model))
                        .foregroundStyle(by: .value("类型", String(localized: "输出")))
                    BarMark(x: .value("Token", item.cacheReadTokens), y: .value("模型", item.model))
                        .foregroundStyle(by: .value("类型", String(localized: "缓存读取")))
                }
            }
            .chartForegroundStyleScale([
                String(localized: "输入"): OMColors.accent,
                String(localized: "输出"): OMColors.accent2,
                String(localized: "缓存读取"): OMColors.success.opacity(0.55),
            ])
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let tokens = value.as(Int.self) { Text(verbatim: ContextUsage.formatTokens(tokens)) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: CGFloat(max(top.count, 1)) * 34 + 56)
            .accessibilityLabel(String(localized: "按模型用量图"))
            ForEach(top) { item in
                LabeledContent {
                    Text(String(localized: "输入 \(item.inputTokens.formatted()) · 输出 \(item.outputTokens.formatted())") + (item.costUSD > 0 ? " · $\(item.costUSD.formatted(.number.precision(.fractionLength(2))))" : ""))
                        .font(OMFonts.small)
                } label: {
                    HStack(spacing: 6) {
                        BrandIconView(BrandIcon.resolve(modelId: item.model, providerPreset: nil, providerName: ""), size: 13)
                        Text(verbatim: item.model)
                    }
                }
            }
        } header: {
            Label("按模型累计", om: "cpu")
        }
    }

    // MARK: - 辅助

    /// 横轴:每隔若干天一个刻度,标签只显示月/日。
    private func dayAxis(count: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: max(1, count / 7))) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
        }
    }

    /// 窗口内出现过的模型(按总量降序,最多 5 个,其余合并忽略以保持图例清晰)。
    private func modelNames(in window: [DailyModelTokens]) -> [String] {
        var totals: [String: Int] = [:]
        for day in window { for (name, tokens) in day.byModel { totals[name, default: 0] += tokens } }
        return totals.sorted { $0.value > $1.value }.prefix(5).map(\.key)
    }
}

/// 概览指标卡:图标 + 数值 + 说明。
private struct UsageTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image.om(icon, size: 15)
                .foregroundStyle(OMColors.accent)
                .frame(width: 30, height: 30)
                .background(OMColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: value).font(OMFonts.title).lineLimit(1).minimumScaleFactor(0.7)
                Text(verbatim: title).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(OMColors.surface, in: RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OMMetrics.controlRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
