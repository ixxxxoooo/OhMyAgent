// @author ixxxxoooo
// 光标移动:字符边界(代理对/组合符/ZWJ/旗帜)、单词移动、双击选词、智能 Home;批量换行行数。

import Foundation
import Testing
@testable import EditorCore

@Suite("光标移动")
struct CursorMotionTests {
    private func rope(_ text: String) -> TextRope { TextRope(text) }

    @Test("字符边界跨过代理对、组合符与 ZWJ 序列")
    func characterBoundaries() {
        let text = rope("a😀e\u{301}b👨‍👩‍👧c")
        // a(0) 😀(1-2) e+́(3-4) b(5) 家庭(6...) c
        #expect(CursorMotion.nextCharacter(0, in: text) == 1)
        #expect(CursorMotion.nextCharacter(1, in: text) == 3)
        #expect(CursorMotion.nextCharacter(3, in: text) == 5)
        let familyEnd = CursorMotion.nextCharacter(6, in: text)
        #expect(familyEnd == text.length - 1)
        #expect(CursorMotion.previousCharacter(familyEnd, in: text) == 6)
        #expect(CursorMotion.previousCharacter(5, in: text) == 3)
        #expect(CursorMotion.previousCharacter(3, in: text) == 1)
        #expect(CursorMotion.previousCharacter(0, in: text) == 0)
        #expect(CursorMotion.nextCharacter(text.length, in: text) == text.length)
    }

    @Test("区域旗帜成对移动")
    func flags() {
        let text = rope("🇨🇳🇺🇸x")
        #expect(CursorMotion.nextCharacter(0, in: text) == 4)
        #expect(CursorMotion.nextCharacter(4, in: text) == 8)
        #expect(CursorMotion.previousCharacter(8, in: text) == 4)
        #expect(CursorMotion.previousCharacter(4, in: text) == 0)
    }

    @Test("单词右移到词尾、左移到词首,行边界处越过换行")
    func wordMotion() {
        let text = rope("foo_bar  baz.qux\nnext")
        #expect(CursorMotion.nextWordEnd(0, in: text) == 7)
        #expect(CursorMotion.nextWordEnd(7, in: text) == 12)
        #expect(CursorMotion.nextWordEnd(12, in: text) == 13)
        #expect(CursorMotion.nextWordEnd(16, in: text) == 17)
        #expect(CursorMotion.previousWordStart(12, in: text) == 9)
        #expect(CursorMotion.previousWordStart(9, in: text) == 0)
        #expect(CursorMotion.previousWordStart(17, in: text) == 16)
        #expect(CursorMotion.previousWordStart(0, in: text) == 0)
        #expect(CursorMotion.nextWordEnd(text.length, in: text) == text.length)
    }

    @Test("双击选词按字符类别取连续段")
    func wordRange() {
        let text = rope("hello  world.x 中文abc")
        #expect(CursorMotion.wordRange(at: 2, in: text) == TextSpan(location: 0, length: 5))
        #expect(CursorMotion.wordRange(at: 5, in: text) == TextSpan(location: 5, length: 2))
        #expect(CursorMotion.wordRange(at: 11, in: text) == TextSpan(location: 7, length: 5))
        #expect(CursorMotion.wordRange(at: 12, in: text) == TextSpan(location: 12, length: 1))
        #expect(CursorMotion.wordRange(at: text.length, in: text) == TextSpan(location: 17, length: 3))
        #expect(CursorMotion.wordRange(at: 15, in: text) == TextSpan(location: 15, length: 2))
    }

    @Test("智能 Home 在首个非空白与行首之间切换")
    func smartHome() {
        let text = rope("x\n    code\n")
        #expect(CursorMotion.smartLineStart(from: 10, in: text) == 6)
        #expect(CursorMotion.smartLineStart(from: 6, in: text) == 2)
        #expect(CursorMotion.smartLineStart(from: 2, in: text) == 6)
        #expect(CursorMotion.lineEnd(from: 4, in: text) == 10)
        #expect(CursorMotion.lineStart(from: 4, in: text) == 2)
        #expect(CursorMotion.leadingWhitespaceLength(ofLine: 1, in: text) == 4)
    }
}

@Suite("批量换行")
struct WrapRowsTests {
    @Test("不换行全为 1;换行时与逐行计算一致")
    func rowsMatchPerLine() {
        let lines = ["short", String(repeating: "word ", count: 40), "", "\t\tindented " + String(repeating: "y", count: 80), "中文" + String(repeating: "字", count: 70)]
        let rope = TextRope(lines.joined(separator: "\n"))
        let metrics = ColumnMetrics()
        #expect(WrapRows.compute(rope: rope, maxColumns: nil, metrics: metrics) == [1, 1, 1, 1, 1])
        let rows = WrapRows.compute(rope: rope, maxColumns: 40, metrics: metrics)
        for (index, line) in lines.enumerated() {
            let expected = LineWrapper.wrapPoints(in: ContiguousArray(line.utf16), maxColumns: 40, metrics: metrics).count + 1
            #expect(Int(rows[index]) == expected)
        }
        #expect(rows[0] == 1 && rows[2] == 1 && rows[1] > 1)
    }

    @Test("最长列数估算")
    func longest() {
        let rope = TextRope("ab\n\tabc\nxxxxxxxxxxxx\n")
        #expect(WrapRows.longestColumns(rope: rope, metrics: ColumnMetrics()) == 12)
    }
}

@MainActor
@Suite("编辑记录的附带信息")
struct AppliedEditInfoTests {
    @Test("编辑携带文本与行信息,逆编辑互换")
    func payload() throws {
        let document = EditorDocument(text: "aa\nbb\ncc")
        var changes: [DocumentChange] = []
        document.addObserver { changes.append($0) }
        try document.replace(TextSpan(location: 1, length: 5), with: "X\nY\nZ")
        document.undo()
        let edit = try #require(changes.first?.edits.first)
        #expect(edit.startLine == 0 && edit.removedLines == 2 && edit.insertedLines == 2)
        #expect(String(decoding: edit.inserted ?? [], as: UTF16.self) == "X\nY\nZ")
        #expect(String(decoding: edit.removed ?? [], as: UTF16.self) == "a\nbb\n")
        let undone = try #require(changes.last?.edits.first)
        #expect(String(decoding: undone.inserted ?? [], as: UTF16.self) == "a\nbb\n")
        #expect(undone.removedLines == 2 && undone.insertedLines == 2)
        #expect(document.text() == "aa\nbb\ncc")
    }
}
