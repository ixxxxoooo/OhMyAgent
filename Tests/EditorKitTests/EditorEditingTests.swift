// @author ixxxxoooo
// 编辑命令(I6):行注释、移动/复制/删除行、缩进、回车缩进、自动闭合、括号匹配、行定位。

import Foundation
import Testing
@testable import EditorKit

/// 应用一次编辑,返回新文本与新选区,便于断言。
private func apply(_ edit: TextEdit?, to text: String) -> (String, NSRange)? {
    guard let edit else { return nil }
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    return (result, edit.selection)
}

@Suite("编辑命令:行注释")
struct LineCommentTests {
    @Test("多行统一加注释,再切换取消")
    func toggle() throws {
        let text = "a\n  b\n\nc\n"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let (commented, sel) = try #require(apply(EditorEditing.toggleLineComment(text: text, selection: all, prefix: "//"), to: text))
        #expect(commented == "// a\n//   b\n\n// c\n")
        let (restored, _) = try #require(apply(EditorEditing.toggleLineComment(text: commented, selection: sel, prefix: "//"), to: commented))
        #expect(restored == text)
    }

    @Test("光标行注释后光标随之右移")
    func caretShift() throws {
        let text = "let x = 1\n"
        let (result, sel) = try #require(apply(EditorEditing.toggleLineComment(text: text, selection: NSRange(location: 4, length: 0), prefix: "//"), to: text))
        #expect(result == "// let x = 1\n")
        #expect(sel.location == 7)
    }

    @Test("全是空行时不处理;前缀映射")
    func edge() {
        #expect(EditorEditing.toggleLineComment(text: "\n\n", selection: NSRange(location: 0, length: 2), prefix: "//") == nil)
        #expect(EditorEditing.commentPrefix(for: .python) == "#")
        #expect(EditorEditing.commentPrefix(for: .swift) == "//")
        #expect(EditorEditing.commentPrefix(for: .json) == nil)
    }
}

@Suite("编辑命令:行操作")
struct LineOpsTests {
    @Test("上移/下移行,选区跟随")
    func move() throws {
        let text = "a\nb\nc\n"
        let (down, sel) = try #require(apply(EditorEditing.moveLines(text: text, selection: NSRange(location: 0, length: 0), up: false), to: text))
        #expect(down == "b\na\nc\n")
        #expect(sel.location == 2)
        let (up, _) = try #require(apply(EditorEditing.moveLines(text: text, selection: NSRange(location: 4, length: 0), up: true), to: text))
        #expect(up == "a\nc\nb\n")
        #expect(EditorEditing.moveLines(text: text, selection: NSRange(location: 0, length: 0), up: true) == nil)
    }

    @Test("末行无换行时上移/下移保持文本完整")
    func moveLastLine() throws {
        let text = "a\nb"
        let (up, _) = try #require(apply(EditorEditing.moveLines(text: text, selection: NSRange(location: 2, length: 0), up: true), to: text))
        #expect(up == "b\na")
        let (down, _) = try #require(apply(EditorEditing.moveLines(text: text, selection: NSRange(location: 0, length: 0), up: false), to: text))
        #expect(down == "b\na")
    }

    @Test("复制行:向下选区落在副本,末行无换行也成立")
    func duplicate() throws {
        let (down, sel) = try #require(apply(EditorEditing.duplicateLines(text: "a\nb\n", selection: NSRange(location: 0, length: 0), down: true), to: "a\nb\n"))
        #expect(down == "a\na\nb\n")
        #expect(sel.location == 2)
        let (last, lastSel) = try #require(apply(EditorEditing.duplicateLines(text: "a\nb", selection: NSRange(location: 2, length: 0), down: true), to: "a\nb"))
        #expect(last == "a\nb\nb")
        #expect(lastSel.location == 4)
        let (upward, _) = try #require(apply(EditorEditing.duplicateLines(text: "a\nb\n", selection: NSRange(location: 2, length: 0), down: false), to: "a\nb\n"))
        #expect(upward == "a\nb\nb\n")
    }

    @Test("删除行与整行范围")
    func delete() throws {
        let (result, sel) = try #require(apply(EditorEditing.deleteLines(text: "a\nb\nc\n", selection: NSRange(location: 2, length: 0)), to: "a\nb\nc\n"))
        #expect(result == "a\nc\n")
        #expect(sel.location == 2)
        // 选区止于下一行行首时不含下一行
        let range = EditorEditing.coveredLines(in: "a\nb\nc\n", selection: NSRange(location: 0, length: 2))
        #expect(range == NSRange(location: 0, length: 2))
    }

    @Test("按行号取范围")
    func lineRange() {
        #expect(EditorEditing.range(ofLine: 1, in: "ab\ncd\nef") == NSRange(location: 0, length: 3))
        #expect(EditorEditing.range(ofLine: 3, in: "ab\ncd\nef") == NSRange(location: 6, length: 2))
        #expect(EditorEditing.range(ofLine: 4, in: "ab\ncd\nef") == nil)
        #expect(EditorEditing.range(ofLine: 0, in: "ab") == nil)
    }
}

@Suite("编辑命令:缩进与回车")
struct IndentTests {
    @Test("多行缩进与反缩进")
    func indent() throws {
        let text = "a\n\nb\n"
        let all = NSRange(location: 0, length: 5)
        let (indented, sel) = try #require(apply(EditorEditing.indent(text: text, selection: all, outdent: false, unit: "  "), to: text))
        #expect(indented == "  a\n\n  b\n")
        let (back, _) = try #require(apply(EditorEditing.indent(text: indented, selection: sel, outdent: true, unit: "  "), to: indented))
        #expect(back == text)
        #expect(EditorEditing.indent(text: text, selection: all, outdent: true, unit: "  ") == nil)
    }

    @Test("回车沿用缩进,块开始多缩一级,括号之间拆三行")
    func newline() {
        let keep = EditorEditing.newline(text: "    foo", caret: 7, unit: "    ")
        #expect(keep.insertion == "\n    ")
        let open = EditorEditing.newline(text: "func f() {", caret: 10, unit: "    ")
        #expect(open.insertion == "\n    ")
        let between = EditorEditing.newline(text: "  {}", caret: 3, unit: "  ")
        #expect(between.insertion == "\n    \n  ")
        #expect(between.caret == 5)
        let py = EditorEditing.newline(text: "if x:", caret: 5, unit: "    ", language: .python)
        #expect(py.insertion == "\n    ")
    }
}

@Suite("编辑命令:自动闭合与括号匹配")
struct PairTests {
    @Test("输入开括号自动补全,闭合符跨越")
    func autoClose() throws {
        let (closed, sel) = try #require(apply(EditorEditing.typed("(", text: "f", selection: NSRange(location: 1, length: 0)), to: "f"))
        #expect(closed == "f()")
        #expect(sel.location == 2)
        let over = try #require(EditorEditing.typed(")", text: "f()", selection: NSRange(location: 2, length: 0)))
        #expect(over.replacement.isEmpty)
        #expect(over.selection.location == 3)
    }

    @Test("选区包裹;单词后的引号与后接字母时不闭合")
    func wrap() throws {
        let (wrapped, sel) = try #require(apply(EditorEditing.typed("[", text: "abc", selection: NSRange(location: 0, length: 3)), to: "abc"))
        #expect(wrapped == "[abc]")
        #expect(sel == NSRange(location: 1, length: 3))
        #expect(EditorEditing.typed("'", text: "don", selection: NSRange(location: 3, length: 0)) == nil)
        #expect(EditorEditing.typed("(", text: "ab", selection: NSRange(location: 1, length: 0)) == nil)
        #expect(EditorEditing.typed("x", text: "", selection: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("退格删除空括号对")
    func backspace() throws {
        let (result, sel) = try #require(apply(EditorEditing.backspacePair(text: "f()", selection: NSRange(location: 2, length: 0)), to: "f()"))
        #expect(result == "f")
        #expect(sel.location == 1)
        #expect(EditorEditing.backspacePair(text: "f(x)", selection: NSRange(location: 2, length: 0)) == nil)
    }

    @Test("括号匹配:嵌套、向前向后、无匹配")
    func match() throws {
        let text = "f(a[1], (b))"
        let pair = try #require(EditorEditing.matchingBracket(in: text, at: 1))
        #expect(pair.open == 1 && pair.close == 11)
        let back = try #require(EditorEditing.matchingBracket(in: text, at: 12))
        #expect(back.open == 1 && back.close == 11)
        #expect(EditorEditing.matchingBracket(in: "(((", at: 0) == nil)
        #expect(EditorEditing.matchingBracket(in: "abc", at: 1) == nil)
    }
}

import AppKit

@MainActor
@Suite("编辑命令:视图集成")
struct EditorEditingViewTests {
    private func makeEditor(_ text: String, language: SyntaxLanguage) -> (CodeEditorView, NSWindow) {
        let editor = CodeEditorView(isEditable: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.setText(text, language: language)
        return (editor, window)
    }

    @Test("输入括号自动闭合、回车缩进、⌘D 加选下一处")
    func typingAndOccurrence() {
        let (editor, window) = makeEditor("", language: .swift)
        defer { window.close() }
        let view = editor.textView
        view.insertText("f", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "f()")
        view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "f()" && view.selectedRange().location == 3)
        view.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertNewline(nil)
        #expect(view.string == "f(){\n    \n}")

        view.string = "foo bar foo"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.addNextOccurrence()
        #expect(view.selectedRange() == NSRange(location: 0, length: 3))
        view.addNextOccurrence()
        #expect(view.selectedRanges.count == 2)
    }

    @Test("括号配对高亮跟随光标;转到行与光标位置")
    func bracketAndGoToLine() {
        let (editor, window) = makeEditor("a(b)\nsecond\nthird", language: .swift)
        defer { window.close() }
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(editor.textView.bracketPair == [1, 3])
        editor.goToLine(3, column: 2)
        #expect(editor.caretPosition.line == 3 && editor.caretPosition.column == 2)
        #expect(editor.textView.bracketPair.isEmpty)
    }
}
