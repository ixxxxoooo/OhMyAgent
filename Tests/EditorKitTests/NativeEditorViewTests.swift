// @author ixxxxoooo
// 原生编辑视图(native2)的无窗口测试:命中/光标矩形互逆、编辑命令、移动、滚动夹取、软换行、绘制不崩溃、语法异步到位。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑视图")
struct NativeEditorViewTests {
    /// 创建一个固定尺寸的视图。
    private func makeView(_ text: String, language: SyntaxLanguage = .plain, wrap: Bool = false, size: CGSize = CGSize(width: 640, height: 400)) -> OMEditorView {
        let document = EditorDocument(text: text)
        let model = NativeEditorModel(document: document, language: language)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.setFrameSize(size)
        view.wrapsLines = wrap
        return view
    }

    private func numbered(_ count: Int) -> String {
        (0..<count).map { "line \($0) value = \($0 * 3)" }.joined(separator: "\n")
    }

    @Test("光标矩形与命中互逆")
    func caretHitRoundTrip() {
        let view = makeView("hello\n\tworld\n中文abc")
        for offset in [0, 3, 5, 6, 7, 12, 14, 17] {
            let rect = view.caretRect(forOffset: offset)
            let back = view.offset(at: CGPoint(x: rect.minX + 0.5, y: rect.midY))
            #expect(back == offset, "偏移 \(offset) 往返得到 \(back)")
        }
    }

    @Test("输入、退格、回车自动缩进")
    func typingAndNewline() {
        let view = makeView("func a() {", language: .swift)
        view.model.setSelections(SelectionSet(caret: view.model.document.length))
        view.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text().hasPrefix("func a() {\n    x"))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(view.model.document.text() == "func a() {\n    ")
    }

    @Test("撤销与重做")
    func undoRedo() {
        let view = makeView("abc")
        view.model.setSelections(SelectionSet(caret: 3))
        view.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text() == "abcd")
        view.performUndo()
        #expect(view.model.document.text() == "abc")
        view.performRedo()
        #expect(view.model.document.text() == "abcd")
    }

    @Test("垂直移动保持偏好列")
    func verticalMotionKeepsColumn() {
        let view = makeView("abcdef\nab\nabcdef")
        view.model.setSelections(SelectionSet(caret: 5))
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(view.model.selections.primary.head == 9)
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(view.model.selections.primary.head == 15)
    }

    @Test("⇧ 移动扩展选区,左右键折叠选区")
    func extendAndCollapse() {
        let view = makeView("hello world")
        view.model.setSelections(SelectionSet(caret: 0))
        view.doCommand(by: #selector(NSResponder.moveWordRightAndModifySelection(_:)))
        #expect(view.model.selections.primary.range == TextSpan(location: 0, length: 5))
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(view.model.selections.primary.head == 5 && view.model.selections.primary.isEmpty)
    }

    @Test("剪切整行与粘贴")
    func cutLineAndPaste() {
        let view = makeView("one\ntwo\nthree")
        view.model.setSelections(SelectionSet(caret: 5))
        view.model.cutSelection()
        #expect(view.model.document.text() == "one\nthree")
        view.model.setSelections(SelectionSet(caret: 0))
        view.model.paste("X\n")
        #expect(view.model.document.text() == "X\none\nthree")
    }

    @Test("多光标粘贴按行分配")
    func multiCursorPasteDistributes() {
        let view = makeView("a\nb")
        view.model.setSelections(SelectionSet([Selection(caret: 1), Selection(caret: 3)]))
        view.model.paste("1\n2")
        #expect(view.model.document.text() == "a1\nb2")
    }

    @Test("滚动被夹取在合法范围")
    func scrollClamps() {
        let view = makeView(numbered(1_000))
        view.scroll(y: -50)
        #expect(view.scrollY == 0)
        view.scroll(y: 1e9)
        #expect(view.scrollY == view.maxScrollY)
        #expect(view.maxScrollY > 1_000 * 10)
    }

    @Test("光标移出视口时自动滚动")
    func revealsCaret() {
        let view = makeView(numbered(500))
        view.model.setSelections(SelectionSet(caret: view.model.document.length))
        #expect(view.scrollY > 0)
        let rect = view.caretRect(forOffset: view.model.document.length)
        #expect(rect.minY >= 0 && rect.maxY <= view.bounds.height)
    }

    @Test("软换行产生多个视图行,命中仍然互逆")
    func wrappedRows() {
        let long = String(repeating: "abcdefghij ", count: 80)
        let view = makeView(long, wrap: true, size: CGSize(width: 320, height: 400))
        #expect(view.model.lineMap.totalRows > 3)
        let target = long.utf16.count - 3
        let rect = view.caretRect(forOffset: target)
        #expect(view.offset(at: CGPoint(x: rect.minX + 0.5, y: rect.midY)) == target)
    }

    @Test("绘制到位图不崩溃且非空")
    func drawsToBitmap() throws {
        let view = makeView(numbered(80), language: .swift)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Issue.record("无法创建位图"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
        // 背景与前景不同色,说明确实画了文字。
        var colors = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
                }
            }
        }
        #expect(colors.count > 3)
    }

    @Test("编辑后行缓存只失效受影响的行")
    func layoutCacheInvalidatesLocally() {
        let view = makeView(numbered(200))
        _ = view.visibleDrawRows()
        let missesBefore = view.cache.misses
        view.model.setSelections(SelectionSet(caret: 4))
        view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = view.visibleDrawRows()
        #expect(view.cache.misses - missesBefore <= 2)
    }

    @Test("在中间插入换行后下方行的排版被平移复用")
    func layoutCacheShiftsAfterNewline() {
        let view = makeView(numbered(200))
        _ = view.visibleDrawRows()
        let missesBefore = view.cache.misses
        view.model.setSelections(SelectionSet(caret: 4))
        view.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = view.visibleDrawRows()
        #expect(view.cache.misses - missesBefore <= 3)
    }

    @Test("语法片段异步到位并带颜色")
    func syntaxArrives() async throws {
        let view = makeView("let value = 42 // note\nfunc go() {}", language: .swift)
        for _ in 0..<100 where view.tokens.syncCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.tokens.syncCount > 0)
        #expect(!view.tokens.spans(intersecting: NSRange(location: 0, length: 20)).isEmpty)
    }

    @Test("输入法组合文本写入文档并在确认时替换")
    func compositionFlow() {
        let view = makeView("")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text() == "ni")
        #expect(view.hasMarkedText())
        view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text() == "你")
        #expect(!view.hasMarkedText())
    }

    @Test("括号自动闭合与跨越")
    func autoClosePairs() {
        let view = makeView("")
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text() == "()")
        view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.model.document.text() == "()")
        #expect(view.model.selections.primary.head == 2)
    }

    @Test("Tab 缩进多行选区,⇧Tab 反缩进")
    func indentOutdent() {
        let view = makeView("a\nb\nc")
        view.model.setSelections(SelectionSet([Selection(anchor: 0, head: 5)]))
        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(view.model.document.text() == "    a\n    b\n    c")
        view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(view.model.document.text() == "a\nb\nc")
    }
}
