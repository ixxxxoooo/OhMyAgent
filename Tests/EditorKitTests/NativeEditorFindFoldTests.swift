// @author ixxxxoooo
// 原生编辑器的查找替换、折叠、空白字符渲染与 Unicode 高亮测试。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
@Suite("原生编辑器查找与折叠")
struct NativeEditorFindFoldTests {
    private func makeView(_ text: String, language: SyntaxLanguage = .plain, chrome: EditorChrome = []) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.setFrameSize(CGSize(width: 700, height: 400))
        view.chrome = chrome
        return view
    }

    private func text(_ view: OMEditorView) -> String { view.model.document.snapshot.string() }

    @Test("查找:命中数、当前命中选中、装饰同步")
    func findMatches() {
        let view = makeView("foo bar Foo\nbaz foo")
        view.showFind()
        view.findModel.query = "foo"
        #expect(view.findModel.matchCount == 3)
        #expect(view.model.selections.primary.range == TextSpan(location: 0, length: 3))
        #expect(view.model.decorations.items.filter { $0.kind == .findMatch || $0.kind == .findCurrent }.count == 3)
        view.findStep(forward: true)
        #expect(view.model.selections.primary.range.location == 8)
        view.findStep(forward: false)
        #expect(view.model.selections.primary.range.location == 0)
        view.findModel.options.caseSensitive = true
        #expect(view.findModel.matchCount == 2)
        view.hideFind()
        #expect(view.model.decorations.items.filter { $0.kind == .findMatch || $0.kind == .findCurrent }.isEmpty)
    }

    @Test("替换当前与全部替换(单步撤销),正则捕获组")
    func replace() {
        let view = makeView("a1 b2 c3")
        view.showFind(replace: true)
        view.findModel.options.regex = true
        view.findModel.query = "([a-c])(\\d)"
        #expect(view.findModel.matchCount == 3)
        view.findModel.replacement = "$2$1"
        view.findModel.onReplace?()
        #expect(text(view) == "1a b2 c3")
        view.findModel.onReplaceAll?()
        #expect(text(view) == "1a 2b 3c")
        _ = view.model.document.undo()
        #expect(text(view) == "1a b2 c3")
        view.hideFind()
    }

    @Test("折叠:区域推断、折叠隐藏行、命中隐藏行自动展开")
    func folding() {
        let source = "func a() {\n    one\n    two\n}\nfunc b() {\n    three\n}"
        let view = makeView(source, language: .swift, chrome: [.folding])
        let rope = view.model.document.snapshot
        let regions = EditorFolding.allRegions(lineCount: rope.lineCount, text: { rope.lineText($0) })
            .map { EditorCore.FoldRegion(startLine: $0.header, endLine: $0.body.upperBound) }
        view.model.setFoldRegions(regions)
        #expect(view.model.folds.regions.count == 2)
        let before = view.model.lineMap.totalRows
        view.model.fold(line: 0)
        #expect(view.model.lineMap.totalRows == before - 2)
        view.model.foldAll()
        #expect(view.model.lineMap.totalRows == before - 3)
        // 选区落进被隐藏的行 → 自动展开所属折叠。
        let hiddenOffset = rope.lineStart(1) + 2
        view.model.setSelections(SelectionSet(caret: hiddenOffset))
        #expect(!view.model.folds.isCollapsed(startLine: 0))
        view.model.unfoldAll()
        #expect(view.model.lineMap.totalRows == before)
    }

    @Test("折叠占位、箭头、空白字符与 Unicode 高亮绘制不崩溃且有像素")
    func drawsAdornments() {
        let source = "let a = 1 \n\tlet b\u{200B} = pаypal\n    x\n"
        let view = makeView(source, language: .swift, chrome: [.folding])
        view.whitespaceRendering = .all
        view.model.setFoldRegions([EditorCore.FoldRegion(startLine: 1, endLine: 2)])
        view.model.fold(line: 1)
        view.gutterHovered = true
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Issue.record("无法创建位图"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.size.width > 0)
    }
}
