// @author ygw
// 并排 Diff:把统一视图的差异块转换为左右对齐的行(删除在左、新增在右,上下文两侧相同)。

import Foundation

/// 并排视图的一行。
public struct SideBySideRow: Sendable, Hashable {
    public var left: DiffLine?
    public var right: DiffLine?
    /// 左/右行在块内 `lines` 中的下标,用于查询行内高亮
    public var leftIndex: Int?
    public var rightIndex: Int?
}

public enum SideBySide {
    /// 把一个差异块转成并排行:连续的删除块与随后的新增块按顺序配对,多出的一侧留空。
    /// - Parameter hunk: 差异块
    /// - Returns: 并排行
    public static func rows(for hunk: DiffHunk) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var removed: [(Int, DiffLine)] = []
        var added: [(Int, DiffLine)] = []

        func flush() {
            let count = max(removed.count, added.count)
            for i in 0..<count {
                let l = i < removed.count ? removed[i] : nil
                let r = i < added.count ? added[i] : nil
                rows.append(SideBySideRow(left: l?.1, right: r?.1, leftIndex: l?.0, rightIndex: r?.0))
            }
            removed.removeAll()
            added.removeAll()
        }

        for (index, line) in hunk.lines.enumerated() {
            switch line.kind {
            case .removed:
                // 新增之后又出现删除:属于下一组改动
                if !added.isEmpty { flush() }
                removed.append((index, line))
            case .added:
                added.append((index, line))
            case .context:
                flush()
                rows.append(SideBySideRow(left: line, right: line, leftIndex: index, rightIndex: index))
            }
        }
        flush()
        return rows
    }
}
