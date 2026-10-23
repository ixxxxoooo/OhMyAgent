// @author ixxxxoooo
// 原生编辑器高级命令测试:行操作、多光标、扩大选择、snippet 会话与镜像、Tab 展开(内置 snippet / Emmet)。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑器命令")
struct NativeEditorCommandTests {
    private func makeModel(_ text: String, language: SyntaxLanguage = .plain) -> NativeEditorModel {
        NativeEditorModel(document: EditorDocument(text: text), language: language)
    }

    private func text(_ model: NativeEditorModel) -> String { model.document.snapshot.string() }

    @Test("行操作一次撤销一步")
    func lineOpsUndo() {
        let model = makeModel("a\nb\nc")
        model.setSelections(SelectionSet(caret: 2))
        model.moveLines(up: true)
        #expect(text(model) == "b\na\nc")
        _ = model.document.undo()
        #expect(text(model) == "a\nb\nc")
        model.duplicateLines(down: true)
        #expect(text(model) == "a\nb\nb\nc")
        model.deleteLines()
        #expect(text(model) == "a\nb\nc")
    }

    @Test("注释切换依语言选择前缀")
    func comment() {
        let model = makeModel("let a = 1\nlet b = 2", language: .swift)
        model.setSelections(SelectionSet([Selection(anchor: 0, head: model.document.length)]))
        model.toggleLineComment()
        #expect(text(model) == "// let a = 1\n// let b = 2")
        model.toggleLineComment()
        #expect(text(model) == "let a = 1\nlet b = 2")
        let css = makeModel("a { color: red }", language: .css)
        css.setSelections(SelectionSet([Selection(anchor: 4, head: 9)]))
        css.toggleLineComment()
        #expect(text(css) == "a { /* color */: red }")
    }

    @Test("⌘D 先选词再逐个加入并回绕;⌘F2 全选")
    func occurrences() {
        let model = makeModel("foo bar foo baz foo")
        model.setSelections(SelectionSet(caret: 1))
        _ = model.selectNextOccurrence()
        #expect(model.selections.primary.range == TextSpan(location: 0, length: 3))
        _ = model.selectNextOccurrence()
        _ = model.selectNextOccurrence()
        #expect(model.selections.selections.map(\.range.location) == [0, 8, 16])
        #expect(model.selectNextOccurrence() == nil)
        model.setSelections(SelectionSet(caret: 9))
        model.selectAllOccurrences()
        #expect(model.selections.selections.count == 3)
        model.insertText("x")
        #expect(text(model) == "x bar x baz x")
    }

    @Test("上下加光标并同时输入")
    func addCursors() {
        let model = makeModel("aaa\nbbb\nccc")
        model.setSelections(SelectionSet(caret: 1))
        model.addCursor(above: false)
        model.addCursor(above: false)
        #expect(model.selections.selections.map(\.head) == [1, 5, 9])
        model.insertText("-")
        #expect(text(model) == "a-aa\nb-bb\nc-cc")
        model.setSelections(SelectionSet([Selection(anchor: 0, head: 3)]))
        model.splitSelectionIntoLines()
        #expect(model.selections.selections.count == 1)
    }

    @Test("扩大与缩小选择")
    func expand() {
        let model = makeModel("call(foo, bar)")
        model.setSelections(SelectionSet(caret: 6))
        model.expandSelection()
        #expect(model.selections.primary.range == TextSpan(location: 5, length: 3))   // foo
        model.expandSelection()
        #expect(model.selections.primary.range == TextSpan(location: 5, length: 8))   // 括号内
        model.expandSelection()
        #expect(model.selections.primary.range == TextSpan(location: 4, length: 10))  // 含括号
        model.shrinkSelection()
        #expect(model.selections.primary.range == TextSpan(location: 5, length: 8))
    }

    @Test("snippet:Tab 依次跳转、镜像同步、到 $0 结束")
    func snippetSession() {
        let model = makeModel("", language: .plain)
        model.insertSnippet("let ${1:name} = ${2:0}; // $1\n$0")
        #expect(text(model) == "let name = 0; // name\n")
        #expect(model.selections.primary.range == TextSpan(location: 4, length: 4))
        model.insertText("count")
        #expect(text(model) == "let count = 0; // count\n")
        #expect(model.snippetSession != nil)
        model.tabAction()
        #expect(model.selections.primary.range == TextSpan(location: 12, length: 1))
        model.insertText("42")
        model.tabAction()
        #expect(model.snippetSession == nil)
        #expect(model.selections.primary.head == model.document.length)
        // 一次 ⌘Z 回退镜像与输入(合并为同一输入组)。
        #expect(text(model) == "let count = 42; // count\n")
    }

    @Test("snippet 内缩进随当前行,⇧Tab 回退占位,离开区域结束会话")
    func snippetIndentAndEnd() {
        let model = makeModel("    ")
        model.setSelections(SelectionSet(caret: 4))
        model.insertSnippet("if ${1:c} {\n\t$0\n}")
        #expect(text(model) == "    if c {\n        \n    }")
        #expect(model.snippetSession != nil)
        model.setSelections(SelectionSet(caret: 0))
        #expect(model.snippetSession == nil)
    }

    @Test("Tab 展开内置 snippet 与 Emmet")
    func tabExpansion() {
        let swift = makeModel("guard", language: .swift)
        swift.setSelections(SelectionSet(caret: 5))
        swift.tabAction()
        #expect(text(swift).hasPrefix("guard condition else {"))
        #expect(swift.snippetSession != nil)

        let html = makeModel("ul>li*2", language: .html)
        html.setSelections(SelectionSet(caret: html.document.length))
        html.tabAction()
        #expect(text(html).contains("<ul>"))
        #expect(text(html).components(separatedBy: "<li>").count == 3)

        let css = makeModel("  m10", language: .css)
        css.setSelections(SelectionSet(caret: css.document.length))
        css.tabAction()
        #expect(text(css) == "  margin: 10px;")

        let plain = makeModel("x")
        plain.setSelections(SelectionSet(caret: 1))
        plain.tabAction()
        #expect(text(plain) == "x   ")
    }
}
