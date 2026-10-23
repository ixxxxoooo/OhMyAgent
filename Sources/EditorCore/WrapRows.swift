// @author ixxxxoooo
// 批量计算每行的软换行行数与不换行时的最长列数:线性扫描文本绳,短行走快速路径(不分配),可在后台线程调用。

import Foundation

public enum WrapRows {
    /// 计算全部行的视图行数。
    /// - Parameters:
    ///   - rope: 文本快照
    ///   - maxColumns: 一行可容纳的视觉列数;`nil` 表示不换行(全部为 1)
    ///   - metrics: 列宽规则
    ///   - indentContinuation: 续行是否缩进
    /// - Returns: 每个模型行的视图行数(≥ 1)
    public static func compute(rope: TextRope, maxColumns: Double?, metrics: ColumnMetrics, indentContinuation: Bool = true) -> [Int32] {
        let lineCount = rope.lineCount
        guard let maxColumns else { return [Int32](repeating: 1, count: lineCount) }
        let worstFactor = max(metrics.wideWidth, Double(metrics.tabSize), 1)
        var result = [Int32](repeating: 1, count: lineCount)
        var start = 0
        for line in 0..<lineCount {
            let next = line + 1 < lineCount ? rope.lineStart(line + 1) : rope.length + 1
            let length = next - 1 - start
            if Double(length) * worstFactor > maxColumns {
                let units = rope.slice(TextSpan(location: start, length: length))
                let points = LineWrapper.wrapPoints(in: units, maxColumns: maxColumns, metrics: metrics, indentContinuation: indentContinuation)
                result[line] = Int32(points.count + 1)
            }
            start = next
        }
        return result
    }

    /// 全文最宽一行的视觉列数(不换行模式估算横向滚动范围)。
    public static func longestColumns(rope: TextRope, metrics: ColumnMetrics) -> Double {
        let lineCount = rope.lineCount
        var widest = 0.0
        var start = 0
        let tabFactor = Double(metrics.tabSize)
        let worstFactor = max(metrics.wideWidth, tabFactor, 1)
        for line in 0..<lineCount {
            let next = line + 1 < lineCount ? rope.lineStart(line + 1) : rope.length + 1
            let length = next - 1 - start
            // 即使按最坏宽度也比已知最宽行窄时可以跳过。
            if Double(length) * worstFactor > widest {
                widest = max(widest, metrics.columns(of: rope.slice(TextSpan(location: start, length: length))))
            }
            start = next
        }
        return widest
    }
}
