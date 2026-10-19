// @author ixxxxoooo
// 跨文本块连续选择的纯计算:选择起点/终点在「文本原子序列」里的坐标,以及由此得到的每个原子的选中范围与复制文本。
// 无 UI:视图层(`SelectionHub`)负责把屏幕位置换算成坐标并把范围画到各文本叶子上。

import Foundation

/// 选择点:第几个文本原子、原子内的 UTF-16 字符偏移。
public struct SelectionPoint: Equatable, Sendable, Comparable {
    /// 原子序号(按屏幕自上而下、同行自左向右)
    public var atom: Int
    /// 原子内偏移(UTF-16 单位,与 `NSString` 一致)
    public var offset: Int

    /// - Parameters:
    ///   - atom: 原子序号
    ///   - offset: 原子内偏移
    public init(atom: Int, offset: Int) {
        self.atom = atom
        self.offset = offset
    }

    public static func < (lhs: SelectionPoint, rhs: SelectionPoint) -> Bool {
        lhs.atom != rhs.atom ? lhs.atom < rhs.atom : lhs.offset < rhs.offset
    }
}

/// 选择计算。
public enum SelectionMath {
    /// 起点/终点规范化为「先后」顺序。
    /// - Parameters:
    ///   - anchor: 按下处
    ///   - focus: 拖到处
    /// - Returns: (起, 止),起不晚于止
    public static func ordered(_ anchor: SelectionPoint, _ focus: SelectionPoint) -> (start: SelectionPoint, end: SelectionPoint) {
        anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    /// 每个原子被选中的范围:起点所在原子取「起点偏移 → 末尾」,终点所在原子取「开头 → 终点偏移」,
    /// 中间的原子整段选中;同一原子内取两点之间。
    /// - Parameters:
    ///   - lengths: 各原子的长度(UTF-16 单位)
    ///   - anchor: 按下处
    ///   - focus: 拖到处
    /// - Returns: 与 `lengths` 等长的范围数组;未选中(或范围为空)的原子为 nil
    public static func ranges(lengths: [Int], anchor: SelectionPoint, focus: SelectionPoint) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: lengths.count)
        guard !lengths.isEmpty else { return result }
        let (start, end) = ordered(anchor, focus)
        guard start != end else { return result }
        let first = max(0, start.atom)
        let last = min(lengths.count - 1, end.atom)
        guard first <= last else { return result }
        for index in first...last {
            let length = max(0, lengths[index])
            let lower = index == start.atom ? min(max(0, start.offset), length) : 0
            let upper = index == end.atom ? min(max(0, end.offset), length) : length
            if lower < upper { result[index] = lower..<upper }
        }
        return result
    }

    /// 把各原子的选中片段拼成复制文本:相邻两段之间空一行,同一行并排的两段(如并排 Diff 的左右两侧)之间只换行。
    /// - Parameters:
    ///   - texts: 各原子的完整文本(UTF-16 偏移与 `ranges` 对应)
    ///   - ranges: `ranges(lengths:anchor:focus:)` 的结果
    ///   - sameRowAsPrevious: 与 `texts` 等长;为真表示该原子与上一个原子在同一行
    /// - Returns: 复制文本;没有选中内容时为空串
    public static func joined(texts: [String], ranges: [Range<Int>?], sameRowAsPrevious: [Bool]) -> String {
        var result = ""
        var wrote = false
        for (index, range) in ranges.enumerated() where index < texts.count {
            guard let range else { continue }
            let piece = (texts[index] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            if wrote { result += (index < sameRowAsPrevious.count && sameRowAsPrevious[index]) ? "\n" : "\n\n" }
            result += piece
            wrote = true
        }
        return result
    }
}
