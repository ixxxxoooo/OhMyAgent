// @author ixxxxoooo
// Tab 幽灵补全的流程测试(不依赖真实模型)。

import AppKit
import EditorCore
import Foundation
import Testing
@testable import EditorKit

@Suite("NativeInlineSuggestion")
@MainActor
struct NativeInlineSuggestionTests {
    private func makeView(_ text: String, caret: Int) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: .plain)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        model.selections = SelectionSet([Selection(caret: caret)])
        return view
    }

    @Test("请求后显示幽灵文字,接受时整段插入并还原装饰")
    func requestShowAccept() async {
        let view = makeView("let a = 1\nlet b", caret: 15)
        view.inlineSuggestion.forceEnabled = true
        view.inlineSuggestion.provider = { prefix, _ in prefix.hasSuffix("let b") ? " = 2\nlet c = 3" : nil }
        await view.inlineSuggestion.debugRequestNow()
        #expect(view.inlineSuggestion.isShowing)
        #expect(view.model.decorations.items.contains { $0.kind == .ghostText })
        view.inlineSuggestion.accept()
        #expect(view.model.document.text() == "let a = 1\nlet b = 2\nlet c = 3")
        #expect(!view.inlineSuggestion.isShowing)
        #expect(!view.model.decorations.items.contains { $0.kind == .ghostText })
    }

    @Test("光标移动后丢弃建议;偏好关闭时不请求")
    func dismissAndDisabled() async {
        let view = makeView("let b", caret: 5)
        view.inlineSuggestion.forceEnabled = true
        view.inlineSuggestion.provider = { _, _ in " = 2" }
        await view.inlineSuggestion.debugRequestNow()
        #expect(view.inlineSuggestion.isShowing)
        view.model.selections = SelectionSet([Selection(caret: 0)])
        view.inlineSuggestion.selectionDidChange()
        #expect(!view.inlineSuggestion.isShowing)
        view.inlineSuggestion.forceEnabled = false
        #expect(!view.inlineSuggestion.isEnabled)
    }

    @Test("光标后还有代码时不请求")
    func skipMidLine() async {
        let view = makeView("foo(bar)", caret: 4)
        view.inlineSuggestion.forceEnabled = true
        view.inlineSuggestion.provider = { _, _ in "X" }
        await view.inlineSuggestion.debugRequestNow()
        #expect(!view.inlineSuggestion.isShowing)
    }
}
