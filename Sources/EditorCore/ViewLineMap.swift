// @author ixxxxoooo
// 视图行映射:每个模型行占几个「视图行」(软换行行数;被折叠隐藏的行为 0),
// 用树状数组(Fenwick)维护前缀和,使「模型行 ↔ 视图行」互转与更新都是 O(log n)。
// 滚动高度 = 视图行总数 × 行高(再加 View Zone);折叠/换行变化只需改少量节点。

import Foundation

/// 模型行与视图行的双向映射。
public struct ViewLineMap: Sendable {
    /// 每个模型行的换行行数(≥ 1,不含折叠影响)。
    private var rows: [Int32]
    /// 每个模型行是否被折叠隐藏。
    private var hidden: [Bool]
    /// 树状数组(1 起),累计「有效视图行数」(隐藏行为 0);用 Int32 省一半内存(视图行总数不会超过 21 亿),溢出时回绕而不崩溃。
    private var tree: [Int32]

    /// 创建映射,所有行占 1 个视图行。
    /// - Parameter lineCount: 模型行数(至少 1)
    public init(lineCount: Int) {
        let count = max(1, lineCount)
        rows = [Int32](repeating: 1, count: count)
        hidden = [Bool](repeating: false, count: count)
        tree = [Int32](repeating: 0, count: count + 1)
        rebuildTree()
    }

    /// 模型行数。
    public var lineCount: Int { rows.count }
    /// 视图行总数(可见行,含软换行)。
    public var totalRows: Int { prefix(lineCount) }

    /// 某模型行的换行行数(不考虑隐藏)。
    public func wrapRows(ofLine line: Int) -> Int { line >= 0 && line < rows.count ? Int(rows[line]) : 1 }
    /// 某模型行是否被隐藏。
    public func isHidden(line: Int) -> Bool { line >= 0 && line < hidden.count && hidden[line] }

    /// 某模型行之前的视图行总数,即它第一个视图行的下标(`line` 可等于行数)。
    public func firstRow(ofLine line: Int) -> Int { prefix(min(max(line, 0), lineCount)) }

    /// 视图行下标对应的模型行与行内第几个视图行;越界夹取到最后一个可见位置。
    public func locate(row: Int) -> (line: Int, rowInLine: Int) {
        let total = totalRows
        if total == 0 { return (0, 0) }
        var remaining = min(max(row, 0), total - 1)
        var position = 0
        var step = 1
        while step * 2 <= lineCount { step *= 2 }
        while step > 0 {
            let next = position + step
            if next <= lineCount, Int(tree[next]) <= remaining {
                position = next
                remaining -= Int(tree[next])
            }
            step /= 2
        }
        return (min(position, lineCount - 1), remaining)
    }

    /// 设置某模型行的换行行数(夹取到 ≥ 1),O(log n)。
    public mutating func setRows(_ count: Int, ofLine line: Int) {
        guard line >= 0, line < rows.count else { return }
        let value = Int32(min(max(count, 1), Int(Int32.max)))
        let delta = Int(value) - Int(rows[line])
        rows[line] = value
        if delta != 0, !hidden[line] { add(delta, at: line) }
    }

    /// 以折叠产生的隐藏行区间整体设置隐藏状态,O(n)。
    public mutating func setHiddenRanges(_ ranges: [ClosedRange<Int>]) {
        for index in hidden.indices { hidden[index] = false }
        for range in ranges {
            let lower = max(range.lowerBound, 0)
            let upper = min(range.upperBound, hidden.count - 1)
            if lower <= upper { for line in lower...upper { hidden[line] = true } }
        }
        rebuildTree()
    }

    /// 用新的换行行数替换 `lines` 区间(文本增删行后调用),O(n)。
    /// - Parameters:
    ///   - lines: 被替换的旧行区间
    ///   - newRows: 替换后各行的换行行数(行数可与旧区间不同)
    public mutating func replaceLines(_ lines: Range<Int>, withRows newRows: [Int32]) {
        let lower = min(max(lines.lowerBound, 0), rows.count)
        let upper = min(max(lines.upperBound, lower), rows.count)
        rows.replaceSubrange(lower..<upper, with: newRows.map { max($0, 1) })
        hidden.replaceSubrange(lower..<upper, with: [Bool](repeating: false, count: newRows.count))
        if rows.isEmpty {
            rows = [1]
            hidden = [false]
        }
        tree = [Int32](repeating: 0, count: rows.count + 1)
        rebuildTree()
    }

    // MARK: 树状数组

    private func prefix(_ count: Int) -> Int {
        var sum = 0
        var index = min(count, rows.count)
        while index > 0 {
            sum += Int(tree[index])
            index -= index & -index
        }
        return sum
    }

    private mutating func add(_ delta: Int, at line: Int) {
        var index = line + 1
        while index <= rows.count {
            tree[index] &+= Int32(truncatingIfNeeded: delta)
            index += index & -index
        }
    }

    private mutating func rebuildTree() {
        let count = rows.count
        if tree.count != count + 1 { tree = [Int32](repeating: 0, count: count + 1) }
        for index in 1...count { tree[index] = hidden[index - 1] ? 0 : rows[index - 1] }
        for index in 1...count {
            let parent = index + (index & -index)
            if parent <= count { tree[parent] &+= tree[index] }
        }
    }
}
