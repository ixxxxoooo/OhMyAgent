// @author ixxxxoooo
// 行号栏改动标记:新增、修改、纯删除、无改动、文件新建。

import Testing
@testable import DiffKit

@Suite("行号栏改动标记")
struct GutterMarksTests {
    @Test("新增、修改与删除分别标记")
    func kinds() {
        let old = "a\nb\nc\nd\ne\nf\ng\n"
        let new = "a\nB\nc\nd\nf\ng\nh\n"
        let marks = LineDiff.gutterMarks(for: LineDiff.diff(old: old, new: new, context: 1))
        #expect(marks[1] == .modified)      // b → B
        #expect(marks[4] == .removed)       // 删除 e,标在其后的 f(新文件第 5 行,0 起始为 4)
        #expect(marks[6] == .added)         // 末尾新增 h
        #expect(marks[0] == nil && marks[2] == nil)
    }

    @Test("替换一行为多行:首行修改,其余为新增")
    func replaceWithMore() {
        let marks = LineDiff.gutterMarks(for: LineDiff.diff(old: "a\nb\nc\n", new: "a\nx\ny\nz\nc\n"))
        #expect(marks[1] == .modified)
        #expect(marks[2] == .added && marks[3] == .added)
    }

    @Test("无改动为空;新文件全部为新增")
    func edge() {
        #expect(LineDiff.gutterMarks(for: LineDiff.diff(old: "a\n", new: "a\n")).isEmpty)
        let created = LineDiff.gutterMarks(for: LineDiff.diff(old: nil, new: "a\nb\n"))
        #expect(created[0] == .added && created[1] == .added)
    }

    @Test("文件末尾被删除时标在最后一行")
    func deleteTail() {
        let marks = LineDiff.gutterMarks(for: LineDiff.diff(old: "a\nb\nc\n", new: "a\nb\n"))
        #expect(marks[1] == .removed)
    }
}
