// @author ixxxxoooo
// 会话内联图表:Markdown 中 ```chart 围栏(JSON)渲染为折线/柱状/面积/饼图,复用画布的图表视图。

import CanvasKit
import SwiftUI

/// ```chart 围栏的解析与缓存。
@MainActor
enum ChartFence {
    private static var cache: [String: CanvasChart] = [:]

    /// 解析围栏内容。
    /// - Parameter source: 围栏内的 JSON 文本
    /// - Returns: 图表;JSON 非法或校验失败为 nil(调用方回退为代码块)
    static func parse(_ source: String) -> CanvasChart? {
        if let hit = cache[source] { return hit }
        guard let data = source.data(using: .utf8), let chart = try? CanvasParser.parseChart(data) else { return nil }
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[source] = chart
        return chart
    }
}

extension ChartFence {
    /// 解析 Mermaid xychart-beta 源码为图表。
    /// - Parameter source: 围栏内容
    /// - Returns: 图表;不是 xychart 或解析失败为 nil(继续走 Mermaid 渲染/回退)
    static func parseXY(_ source: String) -> CanvasChart? {
        XYChartParser.isXYChart(source) ? XYChartParser.parse(source) : nil
    }
}

/// 会话里的图表卡片:直接复用画布图表视图(自带纯色卡片)。
struct ChartFenceView: View {
    let chart: CanvasChart

    var body: some View {
        CanvasChartView(chart: chart)
    }
}
