// @author ixxxxoooo
// 原生编辑器多光标输入测试(从旧 TextKit 引擎的 MultiCursorTests 移植:连续键入、替换选区、退格、回车缩进、自动闭合、一次撤销)。
// 以及 Markdown 列表续行(原 `MarkdownEditCommands` 的核心交互,现接在原生回车上)。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑器多光标与 Markdown 列表续行")
struct NativeMultiCursorTests {
    private func makeModel(_ text: String, language: SyntaxLanguage = .plain) -> NativeEditorModel {
        NativeEditorModel(document: EditorDocument(text: text), language: language)
    }

    private func text(_ model: NativeEditorModel) -> String { model.document.snapshot.string() }
    private func carets(_ model: NativeEditorModel) -> [Int] { model.selections.selections.map(\.head) }

    private func select(_ model: NativeEditorModel, carets: [Int]) {
        model.setSelections(SelectionSet(carets.map { Selection(caret: $0) }))
    }

    @Test("三个光标连续键入:每次都插入到每个光标处,光标随之右移")
    func typing() {
        let model = makeModel("a\nb\nc\n")
        select(model, carets: [1, 3, 5])
        model.insertText("x")
        model.insertText("y")
        #expect(text(model) == "axy\nbxy\ncxy\n")
        #expect(carets(model) == [3, 7, 11])
    }

    @Test("选中的多处相同文本被一次性替换")
    func replaceSelections() {
        let model = makeModel("foo bar foo baz foo\n")
        model.setSelections(SelectionSet([Selection(anchor: 0, head: 3), Selection(anchor: 8, head: 11), Selection(anchor: 16, head: 19)]))
        model.insertText("qux")
        #expect(text(model) == "qux bar qux baz qux\n")
        #expect(carets(model) == [3, 11, 19])
    }

    @Test("多光标退格:每个光标前删一个字符")
    func backspace() {
        let model = makeModel("ab\ncd\nef\n")
        select(model, carets: [2, 5, 8])
        model.deleteBackward()
        #expect(text(model) == "a\nc\ne\n")
        #expect(carets(model) == [1, 3, 5])
    }

    @Test("多光标回车:每个光标处都换行,并保持缩进")
    func newline() {
        let model = makeModel("  a\n  b\n")
        select(model, carets: [3, 7])
        model.insertNewline()
        #expect(text(model) == "  a\n  \n  b\n  \n")
        #expect(carets(model) == [6, 13])
    }

    @Test("多光标输入左括号:各处自动补全右括号")
    func autoClose() {
        let model = makeModel("a\nb\n", language: .swift)
        select(model, carets: [1, 3])
        model.insertText("(")
        #expect(text(model) == "a()\nb()\n")
    }

    @Test("一次撤销还原整次多光标输入")
    func undoIsAtomic() {
        let model = makeModel("a\nb\nc\n")
        select(model, carets: [1, 3, 5])
        model.insertText("x")
        #expect(text(model) == "ax\nbx\ncx\n")
        _ = model.document.undo()
        #expect(text(model) == "a\nb\nc\n")
    }

    // MARK: Markdown 列表续行

    private func enter(_ source: String, at offset: Int) -> (text: String, caret: Int) {
        let model = makeModel(source, language: .markdown)
        model.setSelections(SelectionSet(caret: offset))
        model.insertNewline()
        return (text(model), model.selections.primary.head)
    }

    @Test("无序列表项行尾回车:续出同样的标记")
    func bulletContinues() {
        let result = enter("- a", at: 3)
        #expect(result.text == "- a\n- ")
        #expect(result.caret == 6)
    }

    @Test("有序列表项回车:序号加一;任务项续出未勾选的任务框")
    func orderedAndTaskContinue() {
        #expect(enter("1. a", at: 4).text == "1. a\n2. ")
        #expect(enter("- [x] done", at: 10).text == "- [x] done\n- [ ] ")
    }

    @Test("缩进与引用前缀沿用;空项回车结束列表")
    func prefixAndEnd() {
        #expect(enter("  - a", at: 5).text == "  - a\n  - ")
        #expect(enter("> - a", at: 5).text == "> - a\n> - ")
        let ended = enter("- a\n- ", at: 6)
        #expect(ended.text == "- a\n")
        #expect(ended.caret == 4)
    }

    @Test("行中间回车与非列表行保持默认行为;非 Markdown 语言不续行")
    func notApplicable() {
        #expect(enter("- ab", at: 3).text == "- a\nb")
        #expect(enter("plain", at: 5).text == "plain\n")
        let model = makeModel("- a", language: .swift)
        model.setSelections(SelectionSet(caret: 3))
        model.insertNewline()
        #expect(text(model) == "- a\n")
    }
}
