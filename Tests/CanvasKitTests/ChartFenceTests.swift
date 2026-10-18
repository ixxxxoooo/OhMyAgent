// @author ixxxxoooo
// 会话 ```chart 围栏的解析测试。

import CanvasKit
import Foundation
import Testing

struct ChartFenceTests {
    /// 缺省 type 的图表 JSON 可解析。
    @Test func parsesChartWithoutType() throws {
        let json = #"{"kind":"line","title":"t","labels":["a","b"],"series":[{"name":"s","values":[1,2]}]}"#
        let chart = try CanvasParser.parseChart(Data(json.utf8))
        #expect(chart.kind == .line)
        #expect(chart.series.first?.values == [1, 2])
    }

    /// 系列长度与 labels 不一致、非对象时报错。
    @Test func rejectsInvalid() {
        let bad = #"{"kind":"bar","labels":["a","b"],"series":[{"name":"s","values":[1]}]}"#
        #expect(throws: CanvasError.self) { try CanvasParser.parseChart(Data(bad.utf8)) }
        #expect(throws: CanvasError.self) { try CanvasParser.parseChart(Data("[1]".utf8)) }
    }
}

struct XYChartParserTests {
    /// 用户截图中的 xychart-beta:三条折线、列表横轴。
    @Test func parsesXYChartBeta() throws {
        let source = """
        xychart-beta
            title "示意"
            x-axis ["9:30", "10:30", "11:30"]
            y-axis "涨跌幅 %" -4.5 --> 1.5
            line [-1.5, -2.0, -1.3]
            line [-2.0, -2.5, -3.0]
        """
        let chart = try #require(XYChartParser.parse(source))
        #expect(chart.kind == .line)
        #expect(chart.labels == ["9:30", "10:30", "11:30"])
        #expect(chart.series.count == 2)
    }

    /// 数值范围横轴按等差生成标签;非 xychart 返回 nil。
    @Test func rangeAxisAndNonXY() throws {
        let chart = try #require(XYChartParser.parse("xychart-beta\n x-axis 1 --> 3\n bar [5, 6, 7]"))
        #expect(chart.kind == .bar)
        #expect(chart.labels == ["1", "2", "3"])
        #expect(XYChartParser.parse("flowchart TD\n A-->B") == nil)
    }
}
