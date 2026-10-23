// @author ixxxxoooo
// 行级 Diff:Myers O(ND) 算法 + 分块(hunk)+ 按块回退。
// 纯值类型、无 UI 依赖,可在任意线程调用;超大差异自动退化为整体替换以保证时间/内存上界。

import Foundation

/// 差异操作类别。
public enum DiffOpKind: Sendable, Hashable {
    case equal, delete, insert
}

/// 单个差异操作,指向旧/新文本中的行下标(0 起始)。
public struct DiffOp: Sendable, Hashable {
    public var kind: DiffOpKind
    public var oldIndex: Int?
    public var newIndex: Int?
}

/// 差异行类别。
public enum DiffLineKind: Sendable, Hashable {
    case context, added, removed
}

/// 展示用差异行。
public struct DiffLine: Sendable, Hashable {
    public var kind: DiffLineKind
    public var text: String
    /// 旧文件行号(1 起始)
    public var oldNumber: Int?
    /// 新文件行号(1 起始)
    public var newNumber: Int?
}

/// 差异块:相邻改动合并,并带上下文。
public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var id: Int
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]
    public var added: Int
    public var removed: Int
    /// 覆盖的操作区间(含上下文),回退时使用
    public internal(set) var opRange: Range<Int>

    /// 形如 `@@ -a,b +c,d @@` 的头部。
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

/// 文件级差异。
public struct FileDiff: Sendable {
    public var oldLines: [String]
    public var newLines: [String]
    public var oldTrailingNewline: Bool
    public var newTrailingNewline: Bool
    public var ops: [DiffOp]
    public var hunks: [DiffHunk]
    public var added: Int
    public var removed: Int

    /// 是否没有任何改动。
    public var isEmpty: Bool { hunks.isEmpty }
}

/// 行级 Diff 入口。
public enum LineDiff {
    /// 退化阈值:编辑距离超过该值时,不再精确求解。
    static let maxEditDistance = 4000

    /// 计算差异。
    /// - Parameters:
    ///   - old: 旧文本;nil 表示文件不存在(全部为新增)
    ///   - new: 新文本
    ///   - context: 每个块的上下文行数
    /// - Returns: 文件差异
    public static func diff(old: String?, new: String, context: Int = 3) -> FileDiff {
        let (oldLines, oldTrailing) = split(old ?? "")
        let (newLines, newTrailing) = split(new)
        let ops = computeOps(oldLines, newLines)
        let hunks = buildHunks(ops: ops, oldLines: oldLines, newLines: newLines, context: max(0, context))
        let added = hunks.reduce(0) { $0 + $1.added }
        let removed = hunks.reduce(0) { $0 + $1.removed }
        return FileDiff(oldLines: oldLines, newLines: newLines, oldTrailingNewline: oldTrailing, newTrailingNewline: newTrailing,
                        ops: ops, hunks: hunks, added: added, removed: removed)
    }

    /// 回退指定块:把这些块的改动还原为旧内容,其余块保持新内容。
    /// - Parameters:
    ///   - hunkIds: 需要回退的块 ID
    ///   - diff: 差异
    /// - Returns: 回退后的完整文本
    public static func revert(hunks hunkIds: Set<Int>, in diff: FileDiff) -> String {
        guard !hunkIds.isEmpty else { return join(diff.newLines, trailing: diff.newTrailingNewline) }
        var selected = IndexSet()
        for hunk in diff.hunks where hunkIds.contains(hunk.id) {
            selected.insert(integersIn: hunk.opRange)
        }
        var output: [String] = []
        for (index, op) in diff.ops.enumerated() {
            let reverting = selected.contains(index)
            switch op.kind {
            case .equal:
                if let n = op.newIndex { output.append(diff.newLines[n]) }
            case .delete:
                if reverting, let o = op.oldIndex { output.append(diff.oldLines[o]) }
            case .insert:
                if !reverting, let n = op.newIndex { output.append(diff.newLines[n]) }
            }
        }
        let everything = hunkIds.count == diff.hunks.count
        return join(output, trailing: everything ? diff.oldTrailingNewline : diff.newTrailingNewline)
    }

    // MARK: - 文本与行

    static func split(_ text: String) -> (lines: [String], trailingNewline: Bool) {
        if text.isEmpty { return ([], false) }
        var lines = text.components(separatedBy: "\n")
        var trailing = false
        if lines.last == "" {
            lines.removeLast()
            trailing = true
        }
        return (lines, trailing)
    }

    static func join(_ lines: [String], trailing: Bool) -> String {
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + (trailing ? "\n" : "")
    }

    // MARK: - Myers

    static func computeOps(_ oldLines: [String], _ newLines: [String]) -> [DiffOp] {
        // 公共前后缀先剥离,显著降低实际参与计算的规模
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }

        var ops: [DiffOp] = []
        ops.reserveCapacity(oldLines.count + newLines.count)
        for i in 0..<prefix { ops.append(DiffOp(kind: .equal, oldIndex: i, newIndex: i)) }

        let oldMid = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMid = Array(newLines[prefix..<(newLines.count - suffix)])
        for op in myers(oldMid, newMid) {
            ops.append(DiffOp(kind: op.kind, oldIndex: op.oldIndex.map { $0 + prefix }, newIndex: op.newIndex.map { $0 + prefix }))
        }
        for i in 0..<suffix {
            ops.append(DiffOp(kind: .equal, oldIndex: oldLines.count - suffix + i, newIndex: newLines.count - suffix + i))
        }
        return ops
    }

    private static func myers(_ a: [String], _ b: [String]) -> [DiffOp] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { DiffOp(kind: .insert, oldIndex: nil, newIndex: $0) } }
        if m == 0 { return (0..<n).map { DiffOp(kind: .delete, oldIndex: $0, newIndex: nil) } }

        // 字符串映射为整数,加快比较
        var table: [String: Int] = [:]
        func id(_ s: String) -> Int {
            if let v = table[s] { return v }
            let v = table.count
            table[s] = v
            return v
        }
        let ai = a.map(id), bi = b.map(id)

        let limit = min(n + m, maxEditDistance)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var foundD = -1

        search: for d in 0...limit {
            // 保存步骤 d 之前、k ∈ [-d, d] 的状态
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, ai[x] == bi[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m {
                    foundD = d
                    break search
                }
            }
        }

        guard foundD >= 0 else {
            // 差异过大:整体替换
            return (0..<n).map { DiffOp(kind: .delete, oldIndex: $0, newIndex: nil) }
                + (0..<m).map { DiffOp(kind: .insert, oldIndex: nil, newIndex: $0) }
        }

        // 回溯
        var reversed: [DiffOp] = []
        var x = n, y = m
        var d = foundD
        while d > 0 {
            let snapshot = trace[d]
            func value(_ k: Int) -> Int { snapshot[k + d] }
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && value(k - 1) < value(k + 1)) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = value(prevK)
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                reversed.append(DiffOp(kind: .equal, oldIndex: x - 1, newIndex: y - 1))
                x -= 1; y -= 1
            }
            if x == prevX {
                reversed.append(DiffOp(kind: .insert, oldIndex: nil, newIndex: y - 1))
            } else {
                reversed.append(DiffOp(kind: .delete, oldIndex: x - 1, newIndex: nil))
            }
            x = prevX; y = prevY
            d -= 1
        }
        while x > 0, y > 0 {
            reversed.append(DiffOp(kind: .equal, oldIndex: x - 1, newIndex: y - 1))
            x -= 1; y -= 1
        }
        return reversed.reversed()
    }

    // MARK: - 分块

    private static func buildHunks(ops: [DiffOp], oldLines: [String], newLines: [String], context: Int) -> [DiffHunk] {
        // 1. 找出改动区间(连续的非 equal 操作)
        var blocks: [Range<Int>] = []
        var index = 0
        while index < ops.count {
            if ops[index].kind == .equal { index += 1; continue }
            let start = index
            while index < ops.count, ops[index].kind != .equal { index += 1 }
            blocks.append(start..<index)
        }
        guard !blocks.isEmpty else { return [] }

        // 2. 间隔不超过 2*context 的相邻区间合并为一个块
        var groups: [Range<Int>] = []
        for block in blocks {
            if let last = groups.last, block.lowerBound - last.upperBound <= 2 * context {
                groups[groups.count - 1] = last.lowerBound..<block.upperBound
            } else {
                groups.append(block)
            }
        }

        // 3. 生成块并加入上下文
        var hunks: [DiffHunk] = []
        for (id, group) in groups.enumerated() {
            let start = max(0, group.lowerBound - context)
            let end = min(ops.count, group.upperBound + context)
            var lines: [DiffLine] = []
            var added = 0, removed = 0
            var oldStart = 0, newStart = 0, oldCount = 0, newCount = 0
            var firstOld = true, firstNew = true
            for op in ops[start..<end] {
                switch op.kind {
                case .equal:
                    guard let o = op.oldIndex, let n = op.newIndex else { continue }
                    lines.append(DiffLine(kind: .context, text: newLines[n], oldNumber: o + 1, newNumber: n + 1))
                    if firstOld { oldStart = o + 1; firstOld = false }
                    if firstNew { newStart = n + 1; firstNew = false }
                    oldCount += 1; newCount += 1
                case .delete:
                    guard let o = op.oldIndex else { continue }
                    lines.append(DiffLine(kind: .removed, text: oldLines[o], oldNumber: o + 1, newNumber: nil))
                    if firstOld { oldStart = o + 1; firstOld = false }
                    oldCount += 1; removed += 1
                case .insert:
                    guard let n = op.newIndex else { continue }
                    lines.append(DiffLine(kind: .added, text: newLines[n], oldNumber: nil, newNumber: n + 1))
                    if firstNew { newStart = n + 1; firstNew = false }
                    newCount += 1; added += 1
                }
            }
            hunks.append(DiffHunk(id: id, oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount,
                                  lines: lines, added: added, removed: removed, opRange: start..<end))
        }
        return hunks
    }
}
