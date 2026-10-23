// @author ixxxxoooo
// 列宽规则:等宽字体下把 UTF-16 内容换算成「视觉列」(制表符展开、全角字符占多列、组合符不占宽)。
// 软换行、列选择、不换行时的内容宽度估算共用这一套,保证三处结果一致。

import Foundation

/// 视觉列宽规则。
public struct ColumnMetrics: Sendable, Equatable {
    /// 制表符宽度(列)。
    public var tabSize: Int
    /// 全角/表情等宽字符占的列数(渲染器按实际字体测得后写入,默认 2)。
    public var wideWidth: Double

    /// 创建规则(制表符夹取到 1…16)。
    public init(tabSize: Int = 4, wideWidth: Double = 2) {
        self.tabSize = min(max(tabSize, 1), 16)
        self.wideWidth = max(1, wideWidth)
    }

    /// 单个字符的宽度(列);制表符返回到下一个制表位的距离。
    /// - Parameters:
    ///   - scalar: Unicode 标量值
    ///   - column: 当前所在列(仅制表符使用)
    @inline(__always)
    public func width(of scalar: UInt32, atColumn column: Double) -> Double {
        if scalar >= 0x20 && scalar < 0x7F { return 1 }
        if scalar == 9 {
            let tab = Double(tabSize)
            return tab - column.truncatingRemainder(dividingBy: tab)
        }
        if scalar < 0x20 || (scalar >= 0x7F && scalar < 0xA0) { return 0 }
        if scalar < 0x300 { return 1 }
        if isZeroWidth(scalar) { return 0 }
        return isWide(scalar) ? wideWidth : 1
    }

    /// 零宽:组合附加符、零宽空格/连接符、变体选择符。
    @inline(__always)
    private func isZeroWidth(_ scalar: UInt32) -> Bool {
        (scalar >= 0x300 && scalar <= 0x36F) || (scalar >= 0x200B && scalar <= 0x200F)
            || (scalar >= 0xFE00 && scalar <= 0xFE0F) || scalar == 0xFEFF || (scalar >= 0x1AB0 && scalar <= 0x1AFF)
            || (scalar >= 0xE0100 && scalar <= 0xE01EF)
    }

    /// 东亚宽字符与表情。
    @inline(__always)
    private func isWide(_ scalar: UInt32) -> Bool {
        (scalar >= 0x1100 && scalar <= 0x115F) || (scalar >= 0x2E80 && scalar <= 0xA4CF)
            || (scalar >= 0xAC00 && scalar <= 0xD7A3) || (scalar >= 0xF900 && scalar <= 0xFAFF)
            || (scalar >= 0xFE30 && scalar <= 0xFE6F) || (scalar >= 0xFF00 && scalar <= 0xFF60)
            || (scalar >= 0xFFE0 && scalar <= 0xFFE6) || (scalar >= 0x1F300 && scalar <= 0x1FAFF)
            || (scalar >= 0x20000 && scalar <= 0x3FFFD)
    }

    /// 一行内容的总视觉列数。
    public func columns(of units: ContiguousArray<UInt16>) -> Double {
        var column = 0.0
        var index = 0
        while index < units.count {
            let (scalar, size) = decode(units, at: index)
            column += width(of: scalar, atColumn: column)
            index += size
        }
        return column
    }

    /// 偏移(行内 UTF-16)处的视觉列。
    public func column(inLine units: ContiguousArray<UInt16>, atOffset offset: Int) -> Double {
        var column = 0.0
        var index = 0
        let limit = min(offset, units.count)
        while index < limit {
            let (scalar, size) = decode(units, at: index)
            column += width(of: scalar, atColumn: column)
            index += size
        }
        return column
    }

    /// 视觉列对应的行内偏移:取「不超过该列」的最大字符边界,超出行尾夹取到行尾。
    public func offset(inLine units: ContiguousArray<UInt16>, atColumn target: Double) -> Int {
        var column = 0.0
        var index = 0
        while index < units.count {
            let (scalar, size) = decode(units, at: index)
            let next = column + width(of: scalar, atColumn: column)
            if next > target + 0.0001 { break }
            column = next
            index += size
        }
        return index
    }

    /// 解码 `index` 处的标量与所占 UTF-16 单元数(孤立代理项按单元处理)。
    @inline(__always)
    private func decode(_ units: ContiguousArray<UInt16>, at index: Int) -> (UInt32, Int) {
        let unit = units[index]
        if unit >= 0xD800 && unit < 0xDC00, index + 1 < units.count {
            let low = units[index + 1]
            if low >= 0xDC00 && low < 0xE000 {
                return (0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00), 2)
            }
        }
        return (UInt32(unit), 1)
    }
}
