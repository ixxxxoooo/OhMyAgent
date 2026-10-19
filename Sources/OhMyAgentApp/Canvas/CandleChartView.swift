// @author ixxxxoooo
// 蜡烛图(K 线)视图:Swift Charts 的 RuleMark(影线)+ RectangleMark(实体)拼成,
// 带均线、成交量副图与悬停十字线;涨跌色走 OMColors(默认红涨绿跌,可切换)。

import CanvasKit
import Charts
import DesignSystem
import SwiftUI

/// 蜡烛图卡片(画布块与会话 ```chart 围栏共用,`kind == .candle`)。
struct CandleChartView: View {
    let chart: CanvasChart
    /// 悬停的蜡烛下标;nil 时显示最后一根
    @State private var hovered: Int?
    @State private var plotWidth: CGFloat = 480

    private var count: Int { chart.candles.count }
    private var upColor: Color { chart.upIsRed ? OMColors.danger : OMColors.success }
    private var downColor: Color { chart.upIsRed ? OMColors.success : OMColors.danger }
    private func color(_ candle: CanvasCandle) -> Color { candle.isUp ? upColor : downColor }
    private var hasVolume: Bool { chart.candles.contains { $0.volume != nil } }
    private var shown: Int { min(max(hovered ?? count - 1, 0), count - 1) }

    /// 均线序列:(名称, 下标→值)。
    private var averages: [(name: String, values: [Double?])] {
        chart.movingAverages.map { ("MA\($0)", chart.movingAverage(period: $0)) }
    }

    /// Y 轴范围:包含所有影线与均线,上下留 5% 空隙(不从 0 起)。
    private var yDomain: ClosedRange<Double> {
        let low = chart.candles.map(\.low).min() ?? 0
        let high = chart.candles.map(\.high).max() ?? 1
        let pad = max((high - low) * 0.05, 0.0001)
        return (low - pad)...(high + pad)
    }

    private var xDomain: ClosedRange<Double> { -0.5...(Double(count) - 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chart.title, !title.isEmpty { Text(verbatim: title).font(OMFonts.body.weight(.medium)) }
            readout
            priceChart.frame(height: 240)
            if hasVolume { volumeChart.frame(height: 64) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omSolidCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chart.title ?? String(localized: "K 线图"))
    }

    /// 顶部读数:日期 + 开高低收 + 涨跌幅(相对上一根收盘,首根相对开盘)+ 均线值。
    private var readout: some View {
        let candle = chart.candles[shown]
        let base = shown > 0 ? chart.candles[shown - 1].close : candle.open
        let change = base == 0 ? 0 : (candle.close - base) / base * 100
        return HStack(spacing: 10) {
            Text(verbatim: chart.labels[shown]).foregroundStyle(OMColors.secondaryText)
            Text("开 \(Self.fmt(candle.open))  高 \(Self.fmt(candle.high))  低 \(Self.fmt(candle.low))  收 \(Self.fmt(candle.close))")
            Text(verbatim: String(format: "%+.2f%%", change)).foregroundStyle(color(candle))
            ForEach(Array(averages.enumerated()), id: \.offset) { index, item in
                if let value = item.values[shown] {
                    Text(verbatim: "\(item.name) \(Self.fmt(value))").foregroundStyle(OMColors.chart(index))
                }
            }
        }
        .font(OMFonts.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var priceChart: some View {
        Chart {
            ForEach(Array(chart.candles.enumerated()), id: \.offset) { index, candle in
                RuleMark(x: .value("x", index), yStart: .value("low", candle.low), yEnd: .value("high", candle.high))
                    .foregroundStyle(color(candle))
                RectangleMark(x: .value("x", index), yStart: .value("open", candle.open), yEnd: .value("close", candle.close),
                              width: .fixed(max(1.5, min(14, plotWidth / CGFloat(count) * 0.7))))
                    .foregroundStyle(color(candle))
            }
            ForEach(Array(averages.enumerated()), id: \.offset) { seriesIndex, item in
                ForEach(Array(item.values.enumerated()), id: \.offset) { index, value in
                    if let value {
                        LineMark(x: .value("x", index), y: .value("ma", value), series: .value("series", item.name))
                            .foregroundStyle(OMColors.chart(seriesIndex))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            if hovered != nil { RuleMark(x: .value("x", shown)).foregroundStyle(OMColors.tertiaryText).lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3])) }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis { xAxis }
        .chartOverlay { proxy in hoverLayer(proxy) }
        .chartPlotStyle { $0.background(Color.clear).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 } }
    }

    private var volumeChart: some View {
        Chart {
            ForEach(Array(chart.candles.enumerated()), id: \.offset) { index, candle in
                if let volume = candle.volume {
                    BarMark(x: .value("x", index), y: .value("volume", volume), width: .fixed(max(1.5, min(14, plotWidth / CGFloat(count) * 0.7))))
                        .foregroundStyle(color(candle).opacity(0.7))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(OMFonts.caption) } }
    }

    /// 横轴:约 6 个刻度,标签取自 labels。
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        AxisMarks(values: .stride(by: Double(max(1, count / 6)))) { value in
            if let index = value.as(Int.self), chart.labels.indices.contains(index) {
                AxisValueLabel { Text(verbatim: chart.labels[index]).font(OMFonts.caption) }
            }
        }
    }

    /// 悬停层:鼠标横坐标换算成最近的蜡烛下标。
    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let origin = geo[proxy.plotFrame!].origin.x
                        hovered = proxy.value(atX: point.x - origin, as: Double.self).map { min(max(Int($0.rounded()), 0), count - 1) }
                    case .ended: hovered = nil
                    }
                }
        }
    }

    /// 价格格式:大于 100 保留 2 位,否则最多 4 位有效小数。
    private static func fmt(_ value: Double) -> String {
        abs(value) >= 100 ? String(format: "%.2f", value) : String(format: "%.4g", value)
    }
}
