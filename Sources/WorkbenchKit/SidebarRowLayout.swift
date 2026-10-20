// @author ixxxxoooo
// 项目栏行的窗口化布局(纯逻辑,无视图):
// 项目栏把「置顶 / 会话 / 工作区 → 各项目 → 会话行」展平成一维行数组,各行高度固定但不完全相同
// (分区标题、分组标题、会话行、提示行),因此用前缀和换算位置,只挂载可见窗口内的行,
// 展开 50 个项目、上千条会话时挂载与滚动成本只与可见行数相关。

import Foundation

/// 一组固定高度行的前缀和布局。
public struct SidebarRowLayout: Sendable, Equatable {
    /// 每行顶部相对内容起点的偏移(含行间距,单调递增)
    public let offsets: [Double]
    /// 全部行的总高度(含底部留白)
    public let totalHeight: Double
    private let heights: [Double]

    /// - Parameters:
    ///   - heights: 每行占位高度(调用方把行间距并入每行高度)
    ///   - bottomInset: 底部额外留白
    public init(heights: [Double], bottomInset: Double = 0) {
        var running = 0.0
        var offsets: [Double] = []
        offsets.reserveCapacity(heights.count)
        for height in heights {
            offsets.append(running)
            running += max(0, height)
        }
        self.offsets = offsets
        self.heights = heights
        self.totalHeight = running + max(0, bottomInset)
    }

    /// 行数。
    public var count: Int { offsets.count }

    /// 需要挂载的行区间:覆盖 `[offset, offset + viewport]` 并上下各多挂载 `overscan` 行。
    /// - Parameters:
    ///   - offset: 内容的垂直滚动偏移(点)
    ///   - viewport: 可视区域高度(点)
    ///   - overscan: 上下各多挂载的行数
    /// - Returns: 半开区间;没有行时为空
    public func window(offset: Double, viewport: Double, overscan: Int = 6) -> Range<Int> {
        guard !offsets.isEmpty else { return 0..<0 }
        let top = max(0, offset)
        let bottom = top + max(0, viewport)
        let first = lastIndex(atOrBefore: top)
        let end = firstIndex(atOrAfter: bottom)
        let lower = max(0, first - overscan)
        let upper = min(offsets.count, max(lower, end + overscan))
        return lower..<upper
    }

    /// 窗口之前(上方)的占位高度:恰好等于首个挂载行的顶部偏移。
    /// - Parameter range: `window` 返回的区间
    public func leadingHeight(for range: Range<Int>) -> Double {
        guard range.lowerBound < offsets.count else { return totalHeight }
        return offsets[range.lowerBound]
    }

    /// 窗口之后(下方)的占位高度:总高度减去已挂载行的底边。
    /// - Parameter range: `window` 返回的区间
    public func trailingHeight(for range: Range<Int>) -> Double {
        guard range.upperBound > range.lowerBound, range.upperBound <= offsets.count else {
            return range.isEmpty ? totalHeight : 0
        }
        let last = range.upperBound - 1
        return max(0, totalHeight - (offsets[last] + heights[last]))
    }

    /// 最后一个顶部不超过 `y` 的行索引(二分)。
    private func lastIndex(atOrBefore y: Double) -> Int {
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// 第一个顶部不小于 `y` 的行索引(二分);都小于则返回行数。
    private func firstIndex(atOrAfter y: Double) -> Int {
        var low = 0, high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] >= y { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
