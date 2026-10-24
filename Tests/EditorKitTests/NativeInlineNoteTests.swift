// @author ixxxxoooo
// 行尾内联提示(Git blame)测试:只在光标所在行的行尾绘制文字,不跟随鼠标,其它行不画。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑器内联提示")
struct NativeInlineNoteTests {
    private func makeView() -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: "let a = 1\nlet b = 2\nlet c = 3"), language: .plain)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.syntaxPending = false
        view.setFrameSize(CGSize(width: 800, height: 300))
        view.inlineNote = { "note-\($0)" }
        return view
    }

    /// 某一行(0 起始)行尾之后的区域里非底色像素个数。
    private func inkAfterLineEnd(_ view: OMEditorView, line: Int) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = rep.pixelsWide / Int(view.bounds.width)
        let startX = Int(view.textOriginX + 10 * view.columnWidth + 20)
        let top = Int(view.rowTop(line)) + 2
        let background = view.theme.background.usingColorSpace(.sRGB)
        var count = 0
        for x in stride(from: startX, to: Int(view.bounds.width) - 20, by: 1) {
            for y in top..<(top + Int(view.lineHeight) - 4) {
                guard let color = rep.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB), let background else { continue }
                if abs(color.redComponent - background.redComponent) > 0.15 { count += 1 }
            }
        }
        return count
    }

    @Test("只在光标行画提示:光标移动跟着走,鼠标位置无关,无焦点时不画")
    func caretLineOnly() {
        let view = makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let rope = view.model.document.snapshot
        view.model.setSelections(SelectionSet(caret: rope.lineStart(1)))
        #expect(inkAfterLineEnd(view, line: 1) > 20)
        #expect(inkAfterLineEnd(view, line: 0) == 0)
        view.model.setSelections(SelectionSet(caret: rope.lineStart(0)))
        #expect(inkAfterLineEnd(view, line: 0) > 20)
        #expect(inkAfterLineEnd(view, line: 1) == 0)
        view.inlineNote = nil
        #expect(inkAfterLineEnd(view, line: 0) == 0)
    }
}
