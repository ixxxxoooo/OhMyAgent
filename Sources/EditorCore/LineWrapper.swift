// @author ixxxxoooo
// 软换行计算(等宽字体,按视觉列):给定一行内容与可用列数,返回每个续行的起始偏移。
// 优先在空白与常见分隔符之后断开,没有可断点时硬断;续行可缩进到与首行相同的前导空白。

import Foundation

public enum LineWrapper {
    /// 断行后可作为断点的字符(断在它们之后)。
    @inline(__always)
    private static func breaksAfter(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x2C, 0x3B, 0x29, 0x5D, 0x7D, 0x3E, 0x2F, 0x2D, 0x7C, 0x26: true
        default: false
        }
    }

    /// 计算续行起点。
    /// - Parameters:
    ///   - units: 一行内容(不含换行符)
    ///   - maxColumns: 一行可容纳的视觉列数(≥ 2)
    ///   - metrics: 列宽规则
    ///   - indentContinuation: 续行是否缩进到首行前导空白宽度
    /// - Returns: 升序的行内偏移,每个值是一个续行的开头;不需要换行时为空数组
    public static func wrapPoints(
        in units: UnsafeBufferPointer<UInt16>, maxColumns: Double, metrics: ColumnMetrics, indentContinuation: Bool = true
    ) -> [Int] {
        let limit = max(2, maxColumns)
        // 快速路径:最坏宽度也放得下。
        let worstFactor = max(metrics.wideWidth, Double(metrics.tabSize), 1)
        if Double(units.count) * worstFactor <= limit { return [] }

        // 前导空白宽度(续行缩进),限制在可用宽度的一半以内。
        var indentColumns = 0.0
        if indentContinuation {
            var index = 0
            var column = 0.0
            while index < units.count, units[index] == 0x20 || units[index] == 0x09 {
                column += metrics.width(of: UInt32(units[index]), atColumn: column)
                index += 1
            }
            indentColumns = min(column, limit / 2)
        }

        var points: [Int] = []
        var column = 0.0
        var rowStart = 0
        var lastBreak = -1
        var index = 0
        while index < units.count {
            let unit = units[index]
            var scalar = UInt32(unit)
            var size = 1
            if unit >= 0xD800 && unit < 0xDC00, index + 1 < units.count, units[index + 1] >= 0xDC00, units[index + 1] < 0xE000 {
                scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
                size = 2
            }
            let width = metrics.width(of: scalar, atColumn: column)
            if column + width > limit + 0.0001, index > rowStart {
                // 超出:优先在最近断点处断开,否则就地硬断。
                let breakPoint = lastBreak > rowStart ? lastBreak : index
                points.append(breakPoint)
                rowStart = breakPoint
                lastBreak = -1
                // 重算断点之后已累积的内容宽度。
                column = indentColumns
                var cursor = breakPoint
                while cursor < index {
                    let u = units[cursor]
                    var s = UInt32(u)
                    var step = 1
                    if u >= 0xD800 && u < 0xDC00, cursor + 1 < units.count, units[cursor + 1] >= 0xDC00, units[cursor + 1] < 0xE000 {
                        s = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[cursor + 1]) - 0xDC00)
                        step = 2
                    }
                    column += metrics.width(of: s, atColumn: column)
                    cursor += step
                }
                // 重算后仍放不下(超长单词/单字符):强制把当前字符放到新行,避免死循环。
                if column + width > limit + 0.0001, index > rowStart {
                    points.append(index)
                    rowStart = index
                    column = indentColumns
                }
            }
            column += metrics.width(of: scalar, atColumn: column)
            if size == 1, breaksAfter(unit) { lastBreak = index + 1 }
            index += size
        }
        return points
    }

    /// 便捷版本:接受数组。
    public static func wrapPoints(
        in units: ContiguousArray<UInt16>, maxColumns: Double, metrics: ColumnMetrics, indentContinuation: Bool = true
    ) -> [Int] {
        units.withUnsafeBufferPointer {
            wrapPoints(in: $0, maxColumns: maxColumns, metrics: metrics, indentContinuation: indentContinuation)
        }
    }
}
