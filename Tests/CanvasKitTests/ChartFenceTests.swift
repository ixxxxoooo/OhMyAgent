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
