// @author ixxxxoooo
// 并排 Diff 行转换测试。

import Testing

@testable import DiffKit

@Suite("并排 Diff")
struct SideBySideTests {
    @Test("上下文两侧相同,删除与新增配对")
    func pairing() throws {
        let diff = LineDiff.diff(old: "a\nb\nc\nd\n", new: "a\nB\nc\nd\n")
        let hunk = try #require(diff.hunks.first)
        let rows = SideBySide.rows(for: hunk)
        let changed = try #require(rows.first { $0.left?.kind == .removed })
        #expect(changed.left?.text == "b")
        #expect(changed.right?.text == "B")
        #expect(changed.right?.kind == .added)
        let context = rows.filter { $0.left?.kind == .context }
        #expect(context.allSatisfy { $0.left == $0.right })
    }

    @Test("纯新增与纯删除留空另一侧")
    func unpaired() throws {
        let add = LineDiff.diff(old: "a\n", new: "a\nx\ny\n")
        let addRows = SideBySide.rows(for: try #require(add.hunks.first))
        #expect(addRows.filter { $0.right?.kind == .added }.allSatisfy { $0.left == nil })
        #expect(addRows.filter { $0.right?.kind == .added }.count == 2)
        let del = LineDiff.diff(old: "a\nx\ny\n", new: "a\n")
        let delRows = SideBySide.rows(for: try #require(del.hunks.first))
        #expect(delRows.filter { $0.left?.kind == .removed }.allSatisfy { $0.right == nil })
    }

    @Test("多删少增:多出的删除行右侧为空")
    func uneven() throws {
        let diff = LineDiff.diff(old: "1\n2\n3\n", new: "X\n")
        let rows = SideBySide.rows(for: try #require(diff.hunks.first))
        #expect(rows.count == 3)
        #expect(rows[0].right?.text == "X")
        #expect(rows[1].right == nil && rows[2].right == nil)
    }

    @Test("行数等于两侧最大值之和,索引指回原行")
    func indexes() throws {
        let diff = LineDiff.diff(old: "a\nb\n", new: "a\nc\n")
        let hunk = try #require(diff.hunks.first)
        for row in SideBySide.rows(for: hunk) {
            if let i = row.leftIndex { #expect(hunk.lines[i] == row.left) }
            if let i = row.rightIndex { #expect(hunk.lines[i] == row.right) }
        }
    }
}
