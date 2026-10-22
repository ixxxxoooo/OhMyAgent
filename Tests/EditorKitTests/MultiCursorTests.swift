// @author ixxxxoooo
// 多光标(I6):多个光标/选区下的连续键入、退格、换行、替换、撤销。

import AppKit
import Testing
@testable import EditorKit

@MainActor
@Suite("多光标编辑")
struct MultiCursorTests {
    private func makeEditor(_ text: String) -> (EditorTextView, CodeEditorView, NSWindow) {
        let editor = CodeEditorView(isEditable: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.layoutIfNeeded()
        editor.setText(text, language: .swift)
        window.makeFirstResponder(editor.textView)
        return (editor.textView, editor, window)
    }

    private func select(_ view: EditorTextView, _ ranges: [NSRange]) {
        view.setAllSelections(ranges)
    }

    private func carets(_ view: EditorTextView) -> [Int] { view.allSelections.map(\.location) }

    @Test("三个光标连续键入:每次都插入到每个光标处,光标随之右移")
    func typing() {
        let (view, _, window) = makeEditor("a\nb\nc\n")
        defer { window.close() }
        select(view, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0), NSRange(location: 5, length: 0)])
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "axy\nbxy\ncxy\n")
        #expect(carets(view) == [3, 7, 11])
    }

    @Test("选中的多处相同文本被一次性替换")
    func replaceSelections() {
        let (view, _, window) = makeEditor("foo bar foo baz foo\n")
        defer { window.close() }
        select(view, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)])
        view.insertText("qux", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "qux bar qux baz qux\n")
        #expect(carets(view) == [3, 11, 19])
    }

    @Test("多光标退格:每个光标前删一个字符")
    func backspace() {
        let (view, _, window) = makeEditor("ab\ncd\nef\n")
        defer { window.close() }
        select(view, [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0), NSRange(location: 8, length: 0)])
        view.deleteBackward(nil)
        #expect(view.string == "a\nc\ne\n")
        #expect(carets(view) == [1, 3, 5])
    }

    @Test("多光标回车:每个光标处都换行,并保持缩进")
    func newline() {
        let (view, _, window) = makeEditor("  a\n  b\n")
        defer { window.close() }
        select(view, [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)])
        view.insertNewline(nil)
        #expect(view.string == "  a\n  \n  b\n  \n")
        #expect(carets(view) == [6, 13])
    }

    @Test("多光标输入左括号:各处自动补全右括号")
    func autoClose() {
        let (view, _, window) = makeEditor("f\ng\n")
        defer { window.close() }
        select(view, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "f()\ng()\n")
        #expect(carets(view) == [2, 6])
    }

    @Test("一次撤销还原整次多光标输入")
    func undo() {
        let (view, _, window) = makeEditor("a\nb\n")
        defer { window.close() }
        select(view, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
        view.insertText("zz", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "azz\nbzz\n")
        view.undoManager?.undo()
        #expect(view.string == "a\nb\n")
    }

    @Test("Tab 在多光标处各插入一级缩进")
    func tab() {
        let (view, _, window) = makeEditor("a\nb\n")
        defer { window.close() }
        select(view, [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
        view.insertTab(nil)
        #expect(view.string.hasPrefix(" ") || view.string.hasPrefix("\t"))
        #expect(view.string.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).count == 1 && $0 != $0.trimmingCharacters(in: .whitespaces) }.count == 2)
    }

    @Test("⌘D 逐个加入相同单词,随后键入统一改名")
    func addNextOccurrence() {
        let (view, editor, window) = makeEditor("count = count + count\n")
        defer { window.close() }
        select(view, [NSRange(location: 0, length: 0)])
        editor.perform(.addNextOccurrence)
        editor.perform(.addNextOccurrence)
        editor.perform(.addNextOccurrence)
        #expect(view.selectionCount == 3)
        view.insertText("total", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "total = total + total\n")
    }

    @Test("⌥ 点击加光标后键入;再点同处取消;Esc 收回单光标")
    func optionClickCarets() {
        let (view, _, window) = makeEditor("a\nb\nc\n")
        defer { window.close() }
        select(view, [NSRange(location: 1, length: 0)])
        view.addCaret(at: 3)
        view.addCaret(at: 5)
        #expect(view.selectionCount == 3)
        view.addCaret(at: 3)
        #expect(view.selectionCount == 2)
        view.addCaret(at: 3)
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "a!\nb!\nc!\n")
        view.cancelOperation(nil)
        #expect(view.selectionCount == 1)
    }

    @Test("多光标左右移动、外部选区变化会清除额外光标")
    func moveAndReset() {
        let (view, _, window) = makeEditor("ab\ncd\n")
        defer { window.close() }
        select(view, [NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)])
        view.moveRight(nil)
        #expect(view.allSelections.map(\.location) == [2, 5])
        view.moveLeft(nil)
        view.moveLeft(nil)
        #expect(view.allSelections.map(\.location) == [0, 3])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(view.selectionCount == 1)
    }

    @Test("多光标下行操作(注释/移动)不误改文本")
    func lineOpsAreSkipped() {
        let (view, editor, window) = makeEditor("a\nb\nc\n")
        defer { window.close() }
        select(view, [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)])
        editor.perform(.moveLineDown)
        #expect(view.string == "a\nb\nc\n")
    }
}

@Suite("多编辑合成")
struct EditComposeTests {
    @Test("三处插入:选区按前序长度变化平移")
    func composeInserts() {
        let edits = [
            TextEdit(range: NSRange(location: 1, length: 0), replacement: "xy", selection: NSRange(location: 3, length: 0)),
            TextEdit(range: NSRange(location: 3, length: 0), replacement: "xy", selection: NSRange(location: 5, length: 0)),
        ]
        let result = EditorEditing.compose(edits, in: "a\nb\n")
        #expect(result.text == "axy\nbxy\n")
        #expect(result.selections == [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)])
    }

    @Test("替换与删除混合")
    func composeMixed() {
        let edits = [
            TextEdit(range: NSRange(location: 0, length: 3), replacement: "q", selection: NSRange(location: 1, length: 0)),
            TextEdit(range: NSRange(location: 4, length: 1), replacement: "", selection: NSRange(location: 4, length: 0)),
        ]
        let result = EditorEditing.compose(edits, in: "foo bar")
        #expect(result.text == "q ar")
        #expect(result.selections == [NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)])
    }
}
