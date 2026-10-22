// @author ixxxxoooo
// 编辑器视图(I1):行索引随编辑增量保持一致;不换行模式按最长行估算宽度且不折行;换行/不换行切换。

import AppKit
import Testing
@testable import EditorKit

@MainActor
@Suite("编辑器视图布局")
struct CodeEditorViewLayoutTests {
    /// 创建放进窗口并给定尺寸的编辑器(确保有真实的视口宽度)。
    private func makeEditor(wrap: Bool) -> (CodeEditorView, NSWindow) {
        let editor = CodeEditorView(isEditable: true)
        editor.wrapsLines = wrap
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC 管理生命周期,关闭时不要再 release
        window.contentView = editor
        window.layoutIfNeeded()
        return (editor, window)
    }

    private func sampleText(lines: Int) -> String {
        (0..<lines).map { "let value\($0) = \($0) // 注释 \($0)" }.joined(separator: "\n")
    }

    @Test("小文件装载后行索引即时可用,编辑后与整体重建一致")
    func incrementalIndexMatchesRebuild() {
        let (editor, window) = makeEditor(wrap: true)
        defer { window.close() }
        editor.setText(sampleText(lines: 300), language: .swift)
        #expect(editor.lineIndexIsLive)
        #expect(editor.lineIndex == LineIndex(text: editor.textView.string))

        // 普通输入、回车、选区替换、删除
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.insertText("abc", replacementRange: view.selectedRange())
        #expect(editor.lineIndex == LineIndex(text: view.string))
        view.insertText("\n\t新行\n", replacementRange: view.selectedRange())
        #expect(editor.lineIndex == LineIndex(text: view.string))
        view.setSelectedRange(NSRange(location: 5, length: 400))
        view.insertText("X", replacementRange: view.selectedRange())
        #expect(editor.lineIndex == LineIndex(text: view.string))
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.delete(nil)
        #expect(editor.lineIndex == LineIndex(text: view.string))
        #expect(editor.lineIndexIsLive)
    }

    @Test("撤销与重做也保持行索引一致")
    func undoRedoKeepsIndex() {
        let (editor, window) = makeEditor(wrap: true)
        defer { window.close() }
        editor.setText("a\nb\nc\n", language: .plain)
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertText("多行\n文本\n", replacementRange: view.selectedRange())
        #expect(editor.lineIndex == LineIndex(text: view.string))
        view.undoManager?.undo()
        #expect(editor.lineIndex == LineIndex(text: view.string))
        view.undoManager?.redo()
        #expect(editor.lineIndex == LineIndex(text: view.string))
    }

    @Test("不换行:内容宽度按最长行估算,长行不会被折行")
    func noWrapWidthFollowsLongestLine() {
        let (editor, window) = makeEditor(wrap: false)
        defer { window.close() }
        let longLine = String(repeating: "abcdefghij", count: 60)   // 600 列
        editor.setText("short\n" + longLine + "\nshort", language: .plain)
        let view = editor.textView
        #expect(!editor.isWrapping)
        let container = view.textContainer
        #expect((container?.size.width ?? 0) > 600 * 5)               // 远大于 600pt 视口
        #expect(view.frame.width > 600 * 5)
        // 长行只占一个视觉行:布局片段数 = 3 行
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager?.documentRange ?? NSTextRange(location: view.textLayoutManager!.documentRange.location))
        var fragments = 0
        view.textLayoutManager?.enumerateTextLayoutFragments(from: view.textLayoutManager?.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragments += 1
            #expect(fragment.textLineFragments.count == 1, "第 \(fragments) 段被折行")
            return true
        }
        #expect(fragments == 3)
    }

    @Test("不换行:编辑把某行变长后宽度随之增大")
    func noWrapWidthGrowsOnEdit() {
        let (editor, window) = makeEditor(wrap: false)
        defer { window.close() }
        editor.setText("a\nb", language: .plain)
        let before = editor.textView.frame.width
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.insertText(String(repeating: "x", count: 400), replacementRange: editor.textView.selectedRange())
        #expect(editor.textView.frame.width > before + 400 * 4)
    }

    @Test("换行与不换行可来回切换,横向滚动条随之变化")
    func toggleWrap() {
        let (editor, window) = makeEditor(wrap: true)
        defer { window.close() }
        editor.setText(String(repeating: "word ", count: 400), language: .plain)
        #expect(editor.isWrapping)
        #expect(!editor.scrollView.hasHorizontalScroller)
        editor.wrapsLines = false
        #expect(editor.scrollView.hasHorizontalScroller)
        #expect(editor.textView.textContainer?.widthTracksTextView == false)
        editor.wrapsLines = true
        #expect(editor.textView.textContainer?.widthTracksTextView == true)
        #expect(editor.textView.autoresizingMask.contains(.width))
    }

    @Test("大文件不再强制换行:超过阈值仍按偏好不换行")
    func largeFileKeepsNoWrap() async {
        let (editor, window) = makeEditor(wrap: false)
        defer { window.close() }
        editor.setText(sampleText(lines: CodeEditorView.largeFileLineThreshold + 2_000), language: .swift)
        #expect(!editor.isWrapping)
        #expect(editor.textView.textContainer?.widthTracksTextView == false)
    }

    @Test("键入、回车、撤销后高亮引擎走显式编辑增量,结果与整体重建一致")
    func engineFollowsEditsIncrementally() async throws {
        let (editor, window) = makeEditor(wrap: true)
        defer { window.close() }
        editor.setText(sampleText(lines: 200), language: .swift)
        // 等装载阶段的后台重建完成(引擎建立 tree-sitter 状态)
        try await Task.sleep(for: .milliseconds(500))
        let view = editor.textView
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.insertText("a", replacementRange: view.selectedRange())
        view.insertText("\n    let z = \"你好😀\"\n", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 3, length: 5))
        view.delete(nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await editor.engine.lastParseWasIncremental)
        let text = view.string
        let reference = HighlightEngine()
        await reference.rebuild(text: text, language: .swift)
        let range = NSRange(location: 0, length: (text as NSString).length)
        #expect(await editor.engine.spans(in: range) == reference.spans(in: range))
    }
}
