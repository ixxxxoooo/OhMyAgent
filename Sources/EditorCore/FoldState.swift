// @author ixxxxoooo
// 折叠状态:可折叠区域(行范围)与已折叠集合。区域的来源(缩进/括号/LSP/AST)由上层提供,
// 这里只负责「哪些行被隐藏」、层级折叠与编辑后的行号平移。

import Foundation

/// 可折叠区域:折叠后隐藏 `startLine + 1 ... endLine` 行,起始行保持可见。
public struct FoldRegion: Sendable, Hashable {
    /// 起始行(折叠后仍显示)。
    public var startLine: Int
    /// 结束行(含,折叠后隐藏)。
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = max(endLine, startLine)
    }
}

/// 折叠状态(值类型)。
public struct FoldState: Sendable, Equatable {
    /// 全部可折叠区域,按起始行升序、同起点外层(结束行大)在前,起始行唯一。
    public private(set) var regions: [FoldRegion] = []
    /// 已折叠区域的起始行。
    public private(set) var collapsedStarts: Set<Int> = []

    public init() {}

    /// 替换可折叠区域集合;仍存在的折叠起始行保持折叠,其余丢弃。
    public mutating func setRegions(_ newRegions: [FoldRegion]) {
        var seen = Set<Int>()
        let sorted = newRegions.filter { $0.endLine > $0.startLine }.sorted {
            $0.startLine != $1.startLine ? $0.startLine < $1.startLine : $0.endLine > $1.endLine
        }
        regions = sorted.filter { seen.insert($0.startLine).inserted }
        let starts = Set(regions.map(\.startLine))
        collapsedStarts.formIntersection(starts)
    }

    /// 被隐藏的行区间(已合并、升序、互不相交)。
    public func hiddenRanges() -> [ClosedRange<Int>] {
        // 热路径(视图行换算)大多没有折叠:直接返回,避免每次遍历全部区域
        if collapsedStarts.isEmpty { return [] }
        var result: [ClosedRange<Int>] = []
        for region in regions where collapsedStarts.contains(region.startLine) {
            let hidden = (region.startLine + 1)...region.endLine
            if let last = result.last, hidden.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, hidden.upperBound)
            } else {
                result.append(hidden)
            }
        }
        return result
    }

    /// 某行是否被隐藏。
    public func isHidden(line: Int) -> Bool {
        hiddenRanges().contains { $0.contains(line) }
    }

    /// 某行是否为已折叠区域的起始行。
    public func isCollapsed(startLine: Int) -> Bool { collapsedStarts.contains(startLine) }

    /// 起始行为 `line` 的区域。
    public func region(startingAt line: Int) -> FoldRegion? {
        var low = 0, high = regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if regions[mid].startLine == line { return regions[mid] }
            if regions[mid].startLine < line { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// 包含 `line` 的最内层区域(起始行本身也算包含)。
    public func innermostRegion(containing line: Int) -> FoldRegion? {
        var best: FoldRegion?
        for region in regions where region.startLine <= line {
            if region.endLine >= line { best = region }
        }
        return best
    }

    /// 切换折叠:优先以 `line` 为起点的区域,否则其最内层包含区域。
    @discardableResult
    public mutating func toggle(line: Int) -> Bool {
        guard let region = region(startingAt: line) ?? innermostRegion(containing: line) else { return false }
        if collapsedStarts.contains(region.startLine) { collapsedStarts.remove(region.startLine) } else { collapsedStarts.insert(region.startLine) }
        return true
    }

    /// 折叠包含该行的最内层未折叠区域。
    @discardableResult
    public mutating func fold(line: Int) -> Bool {
        guard let region = region(startingAt: line).flatMap({ collapsedStarts.contains($0.startLine) ? nil : $0 })
                ?? innermostUncollapsed(containing: line) else { return false }
        collapsedStarts.insert(region.startLine)
        return true
    }

    /// 展开包含该行的折叠区域(从外到内:先展开隐藏该行的那层)。
    @discardableResult
    public mutating func unfold(line: Int) -> Bool {
        var changed = false
        for region in regions where collapsedStarts.contains(region.startLine) && region.startLine <= line && line <= region.endLine {
            collapsedStarts.remove(region.startLine)
            changed = true
            break
        }
        return changed
    }

    /// 全部折叠。
    public mutating func foldAll() { collapsedStarts = Set(regions.map(\.startLine)) }
    /// 全部展开。
    public mutating func unfoldAll() { collapsedStarts.removeAll() }

    /// 折叠到某一层级:该层及更深层折叠,更浅层展开(层级从 1 起)。
    public mutating func fold(level: Int) {
        var stack: [FoldRegion] = []
        var result = Set<Int>()
        for region in regions {
            while let top = stack.last, top.endLine < region.startLine { stack.removeLast() }
            if stack.count + 1 >= level { result.insert(region.startLine) }
            stack.append(region)
        }
        collapsedStarts = result
    }

    /// 折叠除包含 `lines` 之外的所有区域(「折叠其他」)。
    public mutating func foldAllExcept(lines: [Int]) {
        collapsedStarts = Set(regions.filter { region in
            !lines.contains { region.startLine <= $0 && $0 <= region.endLine }
        }.map(\.startLine))
    }

    /// 文本行数变化后平移区域。
    /// - Parameters:
    ///   - startLine: 编辑起始行
    ///   - removedLines: 被删除的换行数
    ///   - insertedLines: 新插入的换行数
    public mutating func applyLineEdit(startLine: Int, removedLines: Int, insertedLines: Int) {
        let delta = insertedLines - removedLines
        if delta == 0 { return }
        let affectedEnd = startLine + removedLines
        var updated: [FoldRegion] = []
        var newCollapsed = Set<Int>()
        for region in regions {
            var next = region
            if region.endLine < startLine {
                // 完全在编辑之前。
            } else if region.startLine > affectedEnd {
                next.startLine += delta
                next.endLine += delta
            } else if region.startLine < startLine && affectedEnd <= region.endLine {
                // 编辑发生在区域内部:区域随之伸缩。
                next.endLine += delta
            } else {
                continue
            }
            guard next.endLine > next.startLine else { continue }
            updated.append(next)
            if collapsedStarts.contains(region.startLine) { newCollapsed.insert(next.startLine) }
        }
        regions = updated
        collapsedStarts = newCollapsed
    }

    private func innermostUncollapsed(containing line: Int) -> FoldRegion? {
        var best: FoldRegion?
        for region in regions where region.startLine <= line && region.endLine >= line && !collapsedStarts.contains(region.startLine) {
            best = region
        }
        return best
    }
}
