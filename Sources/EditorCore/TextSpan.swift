// @author ixxxxoooo
// 文本基础类型:UTF-16 偏移区间与行列位置(与 NSRange / LSP 的偏移单位一致)。

import Foundation

/// 文本区间:UTF-16 偏移的半开区间 `[location, location + length)`。
public struct TextSpan: Sendable, Hashable {
    /// 起点偏移(UTF-16)。
    public var location: Int
    /// 长度(UTF-16)。
    public var length: Int

    /// 创建区间;负数会被夹取为 0。
    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    /// 以起止偏移创建区间(`upper < lower` 时视为空区间)。
    public init(lower: Int, upper: Int) {
        let lo = max(0, lower)
        self.init(location: lo, length: max(0, upper - lo))
    }

    /// 终点偏移(不含)。
    public var upperBound: Int { location + length }
    /// 是否为空区间(光标)。
    public var isEmpty: Bool { length == 0 }

    /// 是否包含偏移(闭左开右)。
    public func contains(_ offset: Int) -> Bool { offset >= location && offset < upperBound }

    /// 与另一区间是否相交(空区间贴边不算相交)。
    public func intersects(_ other: TextSpan) -> Bool {
        location < other.upperBound && other.location < upperBound
    }

    /// 转 `NSRange`。
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    /// 由 `NSRange` 创建(`NSNotFound` 视为 0)。
    public init(_ range: NSRange) {
        self.init(location: range.location == NSNotFound ? 0 : range.location, length: range.length)
    }
}

/// 行列位置,行与列均从 0 起,列单位为 UTF-16。
public struct TextPosition: Sendable, Hashable, Comparable {
    /// 行号(0 起)。
    public var line: Int
    /// 列号(0 起,UTF-16)。
    public var column: Int

    /// 创建位置。
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.line != rhs.line ? lhs.line < rhs.line : lhs.column < rhs.column
    }
}
