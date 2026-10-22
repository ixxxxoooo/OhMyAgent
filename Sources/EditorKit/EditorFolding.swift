// @author ixxxxoooo
// 代码折叠(I7)的纯逻辑:按缩进与块头推断可折叠区间、折叠区间随编辑平移。无视图。
// 区间推断只依赖缩进与行尾 `{ ( [ :`,对所有语言一视同仁;不依赖语法树。

import Foundation

/// 一个可折叠区域:块头行与被隐藏的正文行(0 起始、闭区间)。
public struct FoldRegion: Equatable, Sendable {
    /// 块头行(折叠后仍可见)
    public var header: Int
    /// 被隐藏的正文行
    public var body: ClosedRange<Int>

    public init(header: Int, body: ClosedRange<Int>) {
        self.header = header
        self.body = body
    }
}

public enum EditorFolding {
    /// 单个区域向下扫描的最大行数(超出视为不可折叠,避免超大块拖慢交互)。
    public static let scanLimit = 20_000

    /// 求以 `line` 为块头的折叠区域。
    /// - Parameters:
    ///   - line: 块头行(0 起始)
    ///   - lineCount: 总行数
    ///   - text: 取某行文本的闭包(越界返回 nil)
    /// - Returns: 区域;该行不是块头或没有更深缩进的正文时返回 nil
    public static func region(startingAt line: Int, lineCount: Int, text: (Int) -> String?) -> FoldRegion? {
        guard line >= 0, line + 1 < lineCount, let header = text(line), EditorScopes.opensBlock(header),
              let base = EditorScopes.indent(of: header) else { return nil }
        var lastBody: Int?
        var index = line + 1
        let stop = min(lineCount, line + 1 + scanLimit)
        while index < stop {
            guard let content = text(index) else { break }
            if let columns = EditorScopes.indent(of: content) {
                if columns <= base { break }
                lastBody = index
            }
            index += 1
        }
        guard let last = lastBody else { return nil }
        return FoldRegion(header: line, body: (line + 1)...last)
    }

    /// 全文的折叠区域(含嵌套),按块头行升序。
    /// - Parameters:
    ///   - lineCount: 总行数
    ///   - text: 取某行文本的闭包
    public static func allRegions(lineCount: Int, text: (Int) -> String?) -> [FoldRegion] {
        // 先把各行文本取一遍,区间推断里反复访问不再重复切字符串
        let lines = (0..<max(lineCount, 0)).map { text($0) }
        var result: [FoldRegion] = []
        for line in 0..<lines.count {
            if let region = region(startingAt: line, lineCount: lines.count, text: { lines.indices.contains($0) ? lines[$0] : nil }) {
                result.append(region)
            }
        }
        return result
    }

    /// 折叠全部:只折叠最外层区域(嵌套在内的随外层一起隐藏)。
    /// - Parameter regions: `allRegions` 的结果
    public static func outermost(_ regions: [FoldRegion]) -> [FoldRegion] {
        var result: [FoldRegion] = []
        var coveredUntil = -1
        for region in regions.sorted(by: { $0.header < $1.header }) where region.header > coveredUntil {
            result.append(region)
            coveredUntil = region.body.upperBound
        }
        return result
    }

    /// 编辑后调整已折叠(隐藏)的字符范围:编辑与隐藏范围相交或相邻于其内部时取消折叠,位于编辑之后的范围整体平移。
    /// - Parameters:
    ///   - hidden: 隐藏范围(升序、互不重叠)
    ///   - edited: 编辑后的范围(新坐标)
    ///   - delta: 长度变化
    public static func adjust(hidden: [NSRange], edited: NSRange, delta: Int) -> [NSRange] {
        let oldLength = max(edited.length - delta, 0)
        let oldEnd = edited.location + oldLength
        var result: [NSRange] = []
        for range in hidden {
            if oldEnd <= range.location {
                // 编辑完全在隐藏范围之前(含紧邻):整体平移
                result.append(NSRange(location: range.location + delta, length: range.length))
            } else if edited.location >= NSMaxRange(range) {
                result.append(range)
            }
            // 其余情况(相交):丢弃,即自动展开
        }
        return result
    }

    /// 某字符位置是否落在隐藏范围内(二分查找)。
    /// - Parameters:
    ///   - location: UTF-16 偏移
    ///   - hidden: 升序、互不重叠的隐藏范围
    public static func isHidden(_ location: Int, in hidden: [NSRange]) -> Bool {
        var low = 0
        var high = hidden.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = hidden[mid]
            if location < range.location { high = mid - 1 } else if location >= NSMaxRange(range) { low = mid + 1 } else { return true }
        }
        return false
    }

    /// 把行区间换算成要隐藏的字符范围:从正文首行行首到末行行尾(含换行)。
    /// - Parameters:
    ///   - body: 正文行区间
    ///   - lineStart: 某行的行首偏移
    ///   - textLength: 文本总长度
    public static func hiddenRange(for body: ClosedRange<Int>, lineStart: (Int) -> Int?, textLength: Int) -> NSRange? {
        guard let start = lineStart(body.lowerBound) else { return nil }
        let end = lineStart(body.upperBound + 1) ?? textLength
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
