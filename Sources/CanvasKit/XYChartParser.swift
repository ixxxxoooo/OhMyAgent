// @author ixxxxoooo
// Mermaid `xychart-beta` 转图表:会话里的 ```mermaid xychart-beta 围栏用原生图表渲染(MermaidKit 不支持该类型)。

import Foundation

/// Mermaid xychart-beta 解析器。
public enum XYChartParser {
    /// 源码是否为 xychart(-beta) 图。
    /// - Parameter source: Mermaid 源码
    /// - Returns: 首个有效行以 xychart 开头为 true
    public static func isXYChart(_ source: String) -> Bool {
        firstLine(source).lowercased().hasPrefix("xychart")
    }

    /// 解析为图表:`bar`/`line` 各行对应一个系列,同时存在时按折线绘制;`x-axis` 可为列表或数值范围。
    /// - Parameter source: xychart-beta 源码
    /// - Returns: 图表;格式无法识别或数据不合法为 nil
    public static func parse(_ source: String) -> CanvasChart? {
        guard isXYChart(source) else { return nil }
        var title: String?
        var labels: [String] = []
        var xRange: (Double, Double)?
        var series: [CanvasSeries] = []
        var hasLine = false
        for raw in source.split(whereSeparator: \.isNewline).dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("title") {
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if line.hasPrefix("x-axis") {
                if let list = bracketItems(line) { labels = list } else { xRange = range(line) }
            } else if line.hasPrefix("bar") || line.hasPrefix("line") {
                guard let items = bracketItems(line) else { return nil }
                let values = items.compactMap { Double($0) }
                guard values.count == items.count else { return nil }
                if line.hasPrefix("line") { hasLine = true }
                series.append(CanvasSeries(name: String(localized: "系列 \(series.count + 1)"), values: values))
            }
        }
        guard let count = series.first?.values.count, count > 0, series.allSatisfy({ $0.values.count == count }) else { return nil }
        if labels.isEmpty {
            let (low, high) = xRange ?? (1, Double(count))
            let step = count > 1 ? (high - low) / Double(count - 1) : 0
            labels = (0..<count).map { String(format: "%g", low + step * Double($0)) }
        }
        guard labels.count == count else { return nil }
        let chart = CanvasChart(kind: hasLine ? .line : .bar, title: title, labels: labels, series: series)
        return (try? CanvasParser.validate([.chart(chart)]))?.first.flatMap { block in
            if case .chart(let value) = block { return value } else { return nil }
        }
    }

    private static func firstLine(_ source: String) -> String {
        source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    /// 取方括号里逗号分隔的项(去掉引号与空白)。
    private static func bracketItems(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close else { return nil }
        return line[line.index(after: open)..<close].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// 取 `a --> b` 数值范围。
    private static func range(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let low = Double(parts[0].split(separator: " ").last ?? ""),
              let high = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (low, high)
    }
}
