// @author ixxxxoooo
// 原生编辑视图外围能力测试:括号索引与匹配、概览尺标记、粘性滚动、缩略图装配、缩进参考线不崩溃。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑视图外围能力")
struct NativeEditorChromeTests {
    private func makeView(_ text: String, language: SyntaxLanguage = .swift, chrome: EditorChrome = []) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.chrome = chrome
        view.setFrameSize(CGSize(width: 800, height: 400))
        return view
    }

    @Test("括号扫描:深度正确,字符串与注释内的括号被忽略")
    func bracketScanDepthAndIgnore() {
        let source = "f(a[1], {b: \"(\"}) // )\n"
        let items = NativeBracketStore.scan(snapshot: TextRope(source), language: .swift)
        var depths: [(Int, Int, Bool)] = []
        for item in items {
            if case .custom(let code) = item.kind { depths.append((item.range.location, BracketCode.depth(code), BracketCode.isClose(code))) }
        }
        // ( [ ] { } ) 共 6 个,字符串里的 ( 与注释里的 ) 都不计入。
        #expect(depths.count == 6)
        #expect(depths.first?.1 == 0)
        #expect(depths[1].1 == 1)
        #expect(depths.last?.1 == 0 && depths.last?.2 == true)
    }

    @Test("未配对括号被标为 unmatched")
    func unmatched() {
        let items = NativeBracketStore.scan(snapshot: TextRope("a ( b ] c"), language: .swift)
        #expect(items.count == 2)
        for item in items { #expect(item.kind == .custom(BracketCode.unmatched)) }
    }

    @Test("括号匹配:双向找到配对")
    func matching() {
        let text = "func a() { if (x) { y[1] } }"
        let view = makeView(text)
        view.brackets.install(NativeBracketStore.scan(snapshot: view.model.document.snapshot, language: .swift))
        let open = (text as NSString).range(of: "{").location
        let close = (text as NSString).range(of: "}", options: .backwards).location
        view.model.setSelections(SelectionSet(caret: open))
        #expect(view.brackets.match(at: open, rope: view.model.document.snapshot)?.1 == close)
        #expect(view.brackets.match(at: close + 1, rope: view.model.document.snapshot)?.1 == open)
        #expect(view.hasBracketMatch)
        view.model.setSelections(SelectionSet(caret: 2))
        #expect(!view.hasBracketMatch)
    }

    @Test("编辑后括号随装饰平移")
    func bracketsShiftWithEdits() {
        let view = makeView("(a)")
        view.brackets.install(NativeBracketStore.scan(snapshot: view.model.document.snapshot, language: .swift))
        view.model.setSelections(SelectionSet(caret: 0))
        view.insertText("xx", replacementRange: NSRange(location: NSNotFound, length: 0))
        let items = view.brackets.brackets.intersecting(TextSpan(location: 0, length: view.model.document.length))
        #expect(items.map(\.range.location) == [2, 4])
    }

    @Test("启用缩略图与概览尺后文本区右侧让位")
    func rightInset() {
        let view = makeView("a", chrome: [.minimap, .overviewRuler])
        #expect(view.rightInset == NativeMinimapView.width + OMEditorView.rulerWidth)
        #expect(view.textArea.width == view.bounds.width - view.gutterWidth - view.rightInset)
        #expect(view.minimap != nil)
        view.chrome = []
        #expect(view.rightInset == 0 && view.minimap == nil)
    }

    @Test("概览尺包含诊断与行标记")
    func overviewMarks() {
        let lines = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let view = makeView(lines, chrome: [.overviewRuler])
        view.setDiagnostics([EditorDiagnostic(range: NSRange(location: 100, length: 4), severity: .error, message: "x")])
        view.lineMarkers = [200: .added]
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Issue.record("无位图"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(view.overviewMarks.count >= 2)
        #expect(view.overviewMarks.contains { $0.narrow })
    }

    @Test("粘性滚动:滚到嵌套函数内部时出现外层块头")
    func stickyHeaders() {
        var source = "struct Outer {\n    func inner() {\n"
        for index in 0..<120 { source += "        let v\(index) = \(index)\n" }
        source += "    }\n}\n"
        let view = makeView(source, chrome: [.stickyScroll])
        view.scroll(y: 60 * view.lineHeight)
        #expect(view.stickyLines == [0, 1])
        view.scroll(y: 0)
        #expect(view.stickyLines.isEmpty)
    }

    @Test("缩略图、粘性、缩进线一起绘制不崩溃")
    func drawsAllChrome() {
        let text = (0..<300).map { "    func f\($0)() {\n        return [\($0)]\n    }" }.joined(separator: "\n")
        let view = makeView(text, chrome: [.minimap, .stickyScroll, .overviewRuler])
        view.scroll(y: 2_000)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Issue.record("无位图"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let mini = view.minimap, let miniRep = mini.bitmapImageRepForCachingDisplay(in: mini.bounds) else { Issue.record("无缩略图"); return }
        mini.cacheDisplay(in: mini.bounds, to: miniRep)
        #expect(miniRep.pixelsWide > 0)
    }

    @Test("缩进参考线按缩进单位计算层级")
    func indentUnitColumns() {
        let view = makeView("a")
        #expect(view.indentUnitColumns == 4)
        view.model.indentUnit = "\t"
        #expect(view.indentUnitColumns == view.model.metrics.tabSize)
        view.model.indentUnit = "  "
        #expect(view.indentUnitColumns == 2)
    }
}
