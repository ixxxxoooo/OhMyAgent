// @author ixxxxoooo
// 原生编辑器语言智能测试:补全匹配与过滤、补全窗流程、应用外部编辑、内嵌提示与语义着色的排版映射、定义跳转。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑器语言智能")
struct NativeLanguageTests {
    private func makeView(_ text: String, language: SyntaxLanguage = .swift) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.setFrameSize(CGSize(width: 640, height: 400))
        return view
    }

    /// 等待条件成立(最多约 2 秒)。
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: 匹配

    @Test("模糊匹配:前缀、驼峰与不匹配")
    func matcher() {
        #expect(NativeCompletionMatcher.match(query: "", candidate: "abc")?.score == 0)
        let prefix = NativeCompletionMatcher.match(query: "for", candidate: "forEach")
        let camel = NativeCompletionMatcher.match(query: "fe", candidate: "forEach")
        #expect(prefix != nil && camel != nil)
        #expect(camel?.indices == [0, 3])
        #expect(NativeCompletionMatcher.match(query: "xyz", candidate: "forEach") == nil)
        #expect((prefix?.score ?? 0) > (NativeCompletionMatcher.match(query: "ch", candidate: "forEach")?.score ?? 0))
    }

    @Test("过滤按得分排序,同分按 sortText")
    func filterOrdering() {
        let items = [
            NativeCompletionItem(label: "formatter"), NativeCompletionItem(label: "for"), NativeCompletionItem(label: "xfor"),
        ]
        let result = NativeCompletionMatcher.filter(items, query: "for")
        #expect(result.first?.item.label == "for")
        #expect(result.count == 3)
    }

    @Test("取光标前的标识符起点")
    func wordStart() {
        let rope = TextRope("let foo_bar = 1")
        #expect(NativeCompletionMatcher.wordStart(before: 11, in: rope) == 4)
        #expect(NativeCompletionMatcher.wordStart(before: 3, in: rope) == 0)
        #expect(NativeCompletionMatcher.wordStart(before: 4, in: rope) == 4)
    }

    // MARK: 外部编辑

    @Test("应用外部编辑:一次撤销、选区平移、重叠丢弃")
    func applyEdits() {
        let model = NativeEditorModel(document: EditorDocument(text: "aaa bbb ccc"), language: .plain)
        model.setSelections(SelectionSet(caret: 8))
        let changed = model.applyTextEdits([
            NativeTextEdit(range: NSRange(location: 4, length: 3), newText: "BBBBB"),
            NativeTextEdit(range: NSRange(location: 0, length: 3), newText: "A"),
            NativeTextEdit(range: NSRange(location: 5, length: 1), newText: "重叠"),
        ])
        #expect(changed)
        #expect(model.document.snapshot.string() == "A BBBBB ccc")
        // 光标原在 "bbb" 之后的空格后(偏移 8):前方净增 +2 -2 = 0 → 仍在 8。
        #expect(model.selections.primary.head == 8)
        _ = model.document.undo()
        #expect(model.document.snapshot.string() == "aaa bbb ccc")
        #expect(!model.applyTextEdits([NativeTextEdit(range: NSRange(location: 0, length: 3), newText: "aaa")]))
    }

    // MARK: 补全窗

    @Test("补全:触发后出现浮层,输入过滤,回车接受替换前缀")
    func completionFlow() async {
        let view = makeView("let x = fo")
        view.model.setSelections(SelectionSet(caret: view.model.document.length))
        var services = NativeLanguageServices()
        services.completion = { _ in [
            NativeCompletionItem(label: "forEach", kind: .method),
            NativeCompletionItem(label: "format", kind: .function),
            NativeCompletionItem(label: "other"),
        ] }
        view.languageController.services = services
        view.languageController.triggerCompletion(auto: false)
        await waitUntil { view.languageController.isCompletionVisible }
        #expect(view.languageController.isCompletionVisible)
        // 输入 "r" 后 "format"/"forEach" 仍匹配,"other" 不匹配。
        view.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.languageController.isCompletionVisible)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        #expect(enter.map { view.languageController.keyDown($0) } == true)
        #expect(view.model.document.snapshot.string().hasPrefix("let x = for") || view.model.document.snapshot.string().hasPrefix("let x = format"))
        #expect(!view.languageController.isCompletionVisible)
    }

    @Test("补全:片段项走 snippet 引擎并进入占位")
    func completionSnippet() async {
        let view = makeView("fe")
        view.model.setSelections(SelectionSet(caret: 2))
        var services = NativeLanguageServices()
        services.completion = { _ in [NativeCompletionItem(label: "forEach", kind: .snippet, snippet: "forEach { ${1:item} in\n}")] }
        view.languageController.services = services
        view.languageController.triggerCompletion(auto: false)
        await waitUntil { view.languageController.isCompletionVisible }
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        #expect(tab.map { view.languageController.keyDown($0) } == true)
        #expect(view.model.document.snapshot.string().hasPrefix("forEach { item in"))
        #expect(view.model.snippetSession != nil)
    }

    @Test("补全:Esc 关闭浮层且不改文本")
    func completionEscape() async {
        let view = makeView("fo")
        view.model.setSelections(SelectionSet(caret: 2))
        var services = NativeLanguageServices()
        services.completion = { _ in [NativeCompletionItem(label: "for")] }
        view.languageController.services = services
        view.languageController.triggerCompletion(auto: false)
        await waitUntil { view.languageController.isCompletionVisible }
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        #expect(esc.map { view.languageController.keyDown($0) } == true)
        #expect(!view.languageController.isCompletionVisible)
        #expect(view.model.document.snapshot.string() == "fo")
    }

    // MARK: 内嵌提示与语义着色

    @Test("内嵌提示:插入显示文本但不改文档,光标位于提示之前")
    func inlayLayout() {
        let view = makeView("let a = 1\nlet b = 2")
        view.model.decorations.insert(Decoration(id: 1, range: TextSpan(location: 5, length: 0), kind: .inlay, payload: ": Int", removesWhenCollapsed: false))
        view.model.hasInlays = true
        view.cache.clear()
        let located = view.cache.rowLayout(forRow: 0)
        #expect(located != nil)
        #expect(located?.layout.displayLength == "let a = 1".utf16.count + 5)
        #expect(view.model.document.snapshot.string() == "let a = 1\nlet b = 2")
        // 光标在偏移 5 的 x 应不大于「提示后的字符」x:光标在提示之前。
        let before = view.caretRect(forOffset: 5).minX
        let after = view.caretRect(forOffset: 6).minX
        #expect(after - before > view.cache.columnWidth * 5)
        // 行尾提示
        view.model.decorations.insert(Decoration(id: 2, range: TextSpan(location: 9, length: 0), kind: .inlay, payload: " // end", removesWhenCollapsed: false))
        view.cache.clear()
        #expect(view.cache.rowLayout(forRow: 0)?.layout.displayLength == "let a = 1".utf16.count + 5 + 7)
        // 绘制不崩溃
        view.display()
    }

    @Test("语义着色:覆盖语法色并随编辑平移")
    func semanticOverride() {
        let view = makeView("foo bar")
        view.model.decorations.insert(Decoration(id: 1, range: TextSpan(location: 0, length: 3),
                                                 kind: .custom(nativeSemanticBase + Int(SyntaxKind.type.rawValue)), payload: nil))
        view.model.hasSemantic = true
        view.cache.clear()
        #expect(view.cache.rowLayout(forRow: 0) != nil)
        view.model.setSelections(SelectionSet(caret: 0))
        view.model.insertText("x")
        let spans = view.model.decorations.intersecting(TextSpan(location: 0, length: 10))
        #expect(spans.first?.range.location == 1)
        view.display()
    }

    // MARK: 定义跳转

    @Test("定义:同文件直接跳转,跨文件交给宿主")
    func definitionJump() async {
        let view = makeView("a\nb\nc\nd")
        view.model.fileName = "/tmp/x.swift"
        var opened: [NativeLocation] = []
        var services = NativeLanguageServices()
        services.definition = { _ in [NativeLocation(path: "/tmp/x.swift", line: 2, column: 0)] }
        services.openLocation = { opened.append($0) }
        view.languageController.services = services
        view.languageController.goToDefinition(at: 0)
        await waitUntil { view.model.selections.primary.head == 4 }
        #expect(view.model.selections.primary.head == 4)
        #expect(opened.isEmpty)
        services.definition = { _ in [NativeLocation(path: "/tmp/other.swift", line: 7, column: 1)] }
        view.languageController.services = services
        view.languageController.goToDefinition(at: 0)
        await waitUntil { !opened.isEmpty }
        #expect(opened.first?.line == 7)
    }

    @Test("格式化:编辑一次性应用")
    func formatApplies() async {
        let view = makeView("a  =  1")
        var services = NativeLanguageServices()
        services.format = { _ in [NativeTextEdit(range: NSRange(location: 1, length: 2), newText: " "), NativeTextEdit(range: NSRange(location: 4, length: 2), newText: " ")] }
        view.languageController.services = services
        view.languageController.formatDocument()
        await waitUntil { view.model.document.snapshot.string() == "a = 1" }
        #expect(view.model.document.snapshot.string() == "a = 1")
    }
}
