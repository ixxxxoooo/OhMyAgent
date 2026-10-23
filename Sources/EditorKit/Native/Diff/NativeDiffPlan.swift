// @author ixxxxoooo
// 原生 Diff 编辑器的布局方案(纯值类型、无 UI):把 `FileDiff` 转成「改动块 + 字符级配对 + 可折叠的未改动区」,
// 并给出并排视图两侧要插入的对齐占位高度。块与 Git 块(`DiffHunk`)按操作区间一一对应,供暂存/放弃等块级操作使用。

import DiffKit
import EditorCore
import Foundation

/// 一个改动块(连续的删除与新增)。行号均为 0 起。
public struct NativeDiffBlock: Sendable, Equatable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// 所属 Git 块的 id(没有则为 nil)。
    public var hunkID: Int?
    /// 字符级差异:被替换的一对行及其各自变化的字符区间(`Character` 偏移)。
    public var pairs: [Pair]

    /// 一对被替换的行。
    public struct Pair: Sendable, Equatable {
        public var oldLine: Int
        public var newLine: Int
        public var oldRange: Range<Int>
        public var newRange: Range<Int>
    }
}

/// 一段可折叠的未改动区(新旧两侧各自的折叠区域,隐藏行数相同)。
public struct NativeDiffFold: Sendable, Equatable {
    public var old: EditorCore.FoldRegion
    public var new: EditorCore.FoldRegion
}

/// Diff 布局方案。
public struct NativeDiffPlan: Sendable, Equatable {
    public var blocks: [NativeDiffBlock]
    public var folds: [NativeDiffFold]

    /// 空方案(没有差异)。
    public static let empty = NativeDiffPlan(blocks: [], folds: [])

    /// 并排视图某一侧在块之后需要补的空白行数(让两侧对齐)。
    /// - Parameters:
    ///   - block: 改动块
    ///   - oldSide: true 为左(旧)侧
    public static func padding(for block: NativeDiffBlock, oldSide: Bool) -> Int {
        oldSide ? max(block.newCount - block.oldCount, 0) : max(block.oldCount - block.newCount, 0)
    }

    /// 由文件差异构建方案。
    /// - Parameters:
    ///   - diff: 行级差异(含全文操作序列)
    ///   - context: 折叠未改动区时两端保留的上下文行数
    ///   - minFold: 至少隐藏多少行才折叠
    public static func make(from diff: FileDiff, context: Int = 3, minFold: Int = 3) -> NativeDiffPlan {
        var blocks: [NativeDiffBlock] = []
        var opRanges: [Range<Int>] = []
        let ops = diff.ops
        var index = 0
        var oldCursor = 0, newCursor = 0
        while index < ops.count {
            if ops[index].kind == .equal {
                oldCursor = (ops[index].oldIndex ?? oldCursor) + 1
                newCursor = (ops[index].newIndex ?? newCursor) + 1
                index += 1
                continue
            }
            let begin = index
            var deletes: [Int] = [], inserts: [Int] = []
            while index < ops.count, ops[index].kind != .equal {
                if let old = ops[index].oldIndex { deletes.append(old) }
                if let new = ops[index].newIndex { inserts.append(new) }
                index += 1
            }
            var block = NativeDiffBlock(oldStart: oldCursor, oldCount: deletes.count, newStart: newCursor, newCount: inserts.count, hunkID: nil, pairs: [])
            for offset in 0..<min(deletes.count, inserts.count) {
                let oldLine = deletes[offset], newLine = inserts[offset]
                guard diff.oldLines.indices.contains(oldLine), diff.newLines.indices.contains(newLine),
                      let ranges = InlineDiff.changedRanges(old: diff.oldLines[oldLine], new: diff.newLines[newLine]) else { continue }
                block.pairs.append(.init(oldLine: oldLine, newLine: newLine, oldRange: ranges.old, newRange: ranges.new))
            }
            blocks.append(block)
            opRanges.append(begin..<index)
            oldCursor += deletes.count
            newCursor += inserts.count
        }
        for (position, range) in opRanges.enumerated() {
            blocks[position].hunkID = diff.hunks.first { $0.opRange.lowerBound <= range.lowerBound && $0.opRange.upperBound >= range.upperBound }?.id
        }
        return NativeDiffPlan(blocks: blocks, folds: folds(for: blocks, oldTotal: diff.oldLines.count, newTotal: diff.newLines.count,
                                                           context: max(context, 0), minFold: max(minFold, 1)))
    }

    /// 计算未改动区的折叠:首段保留首行(作为折叠起始行),中间段两端各留 `context` 行,末段只留开头 `context` 行。
    private static func folds(for blocks: [NativeDiffBlock], oldTotal: Int, newTotal: Int, context: Int, minFold: Int) -> [NativeDiffFold] {
        var result: [NativeDiffFold] = []
        var oldCursor = 0, newCursor = 0
        func addGap(oldEnd: Int, newEnd: Int, leading: Bool, trailing: Bool) {
            let length = oldEnd - oldCursor
            guard length > 0, length == newEnd - newCursor else { return }
            let head = leading ? 1 : context
            let tail = trailing ? 0 : context
            let hidden = length - head - tail
            guard hidden >= minFold else { return }
            let oldStart = oldCursor + head - 1, newStart = newCursor + head - 1
            result.append(NativeDiffFold(old: EditorCore.FoldRegion(startLine: oldStart, endLine: oldStart + hidden),
                                         new: EditorCore.FoldRegion(startLine: newStart, endLine: newStart + hidden)))
        }
        for (position, block) in blocks.enumerated() {
            addGap(oldEnd: block.oldStart, newEnd: block.newStart, leading: position == 0, trailing: false)
            oldCursor = block.oldStart + block.oldCount
            newCursor = block.newStart + block.newCount
        }
        addGap(oldEnd: oldTotal, newEnd: newTotal, leading: blocks.isEmpty, trailing: true)
        return result
    }
}
