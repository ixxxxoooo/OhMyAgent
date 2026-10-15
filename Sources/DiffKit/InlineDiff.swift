// @author ygw
// 行内(词级)差异:对被替换的一对行,找出各自真正变化的字符区间,供视图做更深的高亮。
// 做法:去掉公共前缀与后缀,再向外扩展到词边界;变化占比过大时视为整行替换,不做行内高亮。

import Foundation

/// 行内差异计算。
public enum InlineDiff {
    /// 一对行的变化区间(以 `Character` 偏移计)。
    /// - Parameters:
    ///   - old: 旧行
    ///   - new: 新行
    /// - Returns: 旧/新行各自的变化区间;无法给出有意义的高亮(相同、过长、差异过大)时为 nil
    public static func changedRanges(old: String, new: String) -> (old: Range<Int>, new: Range<Int>)? {
        let a = Array(old), b = Array(new)
        guard a != b, a.count <= 600, b.count <= 600 else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var oldRange = prefix..<(a.count - suffix)
        var newRange = prefix..<(b.count - suffix)
        oldRange = expand(oldRange, in: a)
        newRange = expand(newRange, in: b)
        // 变化占了绝大部分:整行替换更直观
        let oldShare = a.isEmpty ? 1 : Double(oldRange.count) / Double(a.count)
        let newShare = b.isEmpty ? 1 : Double(newRange.count) / Double(b.count)
        if oldShare > 0.85, newShare > 0.85 { return nil }
        return (oldRange, newRange)
    }

    /// 为一个块的各行计算行内高亮区间:连续的删除段与紧随其后的新增段按顺序一一配对。
    /// - Parameter lines: 块内的行
    /// - Returns: 与 `lines` 等长;不需要高亮的行为 nil
    public static func highlights(for lines: [DiffLine]) -> [Range<Int>?] {
        var result = [Range<Int>?](repeating: nil, count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            for offset in 0..<pairs {
                if let ranges = changedRanges(old: lines[index + offset].text, new: lines[removedEnd + offset].text) {
                    result[index + offset] = ranges.old
                    result[removedEnd + offset] = ranges.new
                }
            }
            index = max(addedEnd, index + 1)
        }
        return result
    }

    /// 把区间向两侧扩展到词边界(字母、数字、下划线算词字符),避免高亮切断单词。
    private static func expand(_ range: Range<Int>, in chars: [Character]) -> Range<Int> {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var lower = range.lowerBound, upper = range.upperBound
        while lower > 0, lower < chars.count, isWord(chars[lower - 1]), isWord(chars[lower]) { lower -= 1 }
        while upper > 0, upper < chars.count, isWord(chars[upper - 1]), isWord(chars[upper]) { upper += 1 }
        return lower..<max(lower, upper)
    }
}
