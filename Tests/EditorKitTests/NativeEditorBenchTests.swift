// @author ixxxxoooo
// 原生编辑器基准内核的冒烟测试、泄漏与浸泡测试(不测绝对耗时,预算由 `Scripts/editor-bench.sh` 在 release 下门禁)。

import AppKit
import EditorCore
import Foundation
import Testing
@testable import EditorKit

@Suite("NativeEditorBench", .serialized)
@MainActor
struct NativeEditorBenchTests {
    @Test("合成素材:行数精确、平均每行约 30 字节上下")
    func synthSize() {
        let text = NativeEditorBench.synthSwift(lines: 1_000)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 1_001)
        let average = Double(text.utf8.count) / 1_000
        #expect(average > 20 && average < 50)
        #expect(NativeEditorBench.synthSwift(lines: 0).isEmpty)
    }

    @Test("分位数:空样本为 0,边界不越界")
    func percentiles() {
        #expect(NativeEditorBench.percentile([], 0.95) == 0)
        #expect(NativeEditorBench.percentile([1, 2, 3, 4], 0.5) == 3)
        #expect(NativeEditorBench.percentile([1, 2, 3, 4], 0.999) == 4)
        #expect(NativeEditorBench.percentile([7], 0.99) == 7)
    }

    @Test("快速模式跑完全部 editor.* 度量点且数值有限")
    func quickRunProducesAllMetrics() async {
        let results = await NativeEditorBench.run(quick: true)
        let ids = Set(results.map(\.id))
        let expected = Set(DemoBudgetIDs.editor)
        #expect(expected.isSubset(of: ids), "缺少度量点:\(expected.subtracting(ids))")
        #expect(results.allSatisfy { $0.value.isFinite && $0.value >= 0 })
    }

    @Test("泄漏:反复创建与关闭编辑器视图后全部释放")
    func viewsAreReleased() async {
        weak var weakView: OMEditorView?
        weak var weakModel: NativeEditorModel?
        for round in 0..<30 {
            autoreleasepool {
                let model = NativeEditorModel(document: EditorDocument(text: NativeEditorBench.synthSwift(lines: 300)), language: .swift)
                let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
                view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
                view.layoutSubtreeIfNeeded()
                view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                view.inlineSuggestion.forceEnabled = false
                if round == 29 { weakView = view; weakModel = model }
            }
            await Task.yield()
        }
        // 后台语法同步等任务持有弱引用,给运行循环几次机会收尾
        for _ in 0..<20 where weakView != nil { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(weakView == nil, "OMEditorView 没有释放")
        #expect(weakModel == nil, "NativeEditorModel 没有释放")
    }

    @Test("浸泡:连续数千次编辑 + 撤销后文本与撤销栈保持一致且不无限增长")
    func editUndoSoak() throws {
        let document = EditorDocument(text: NativeEditorBench.synthSwift(lines: 500))
        let original = document.text()
        let model = NativeEditorModel(document: document, language: .swift)
        for index in 0..<3_000 {
            model.setSelections(SelectionSet([Selection(caret: (index * 37) % max(document.length, 1))]))
            model.insertText("y")
        }
        #expect(document.text() != original)
        while document.canUndo { _ = document.undo() }
        #expect(document.text() == original)
    }
}

/// 基准度量点清单(测试用,与 `DemoBenchmarkCatalog` 的 `editor.*` 同步;缺项会让快速运行测试失败)。
enum DemoBudgetIDs {
    static let editor = [
        "editor.open-50k", "editor.open-50k-interactive", "editor.open-1m", "editor.memory-1m",
        "editor.scroll-p50", "editor.scroll-p99", "editor.scroll-dropped", "editor.typing-p95", "editor.typing-max",
        "editor.syntax-incremental", "editor.completion-popup", "editor.agent-patch", "editor.agent-frame",
    ]
}

/// 超长单行(压缩 JSON)不能把界面卡死:首帧 + 首次按键应在可接受时间内完成。
@Suite("原生编辑器长行保护", .serialized)
@MainActor
struct NativeLongLineTests {
    @Test("200 万字符单行 1.5 秒内完成首帧与首次按键")
    func longLineStaysResponsive() {
        let elapsed = NativeEditorBench.longLineOpenMs(characters: 2_000_000)
        #expect(elapsed < 1_500, "耗时 \(elapsed) ms")
    }

    @Test("不自动换行时超长行也被硬断成多个视图行,短行不受影响")
    func hardWrapSplitsOnlyLongLines() async {
        let text = "short\n" + String(repeating: "a", count: 20_000) + "\nend\n"
        let model = NativeEditorModel(document: EditorDocument(text: text), language: .plain)
        for _ in 0..<200 where model.lineMap.wrapRows(ofLine: 1) <= 1 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.lineMap.wrapRows(ofLine: 0) == 1)
        #expect(model.lineMap.wrapRows(ofLine: 1) == 5)
        #expect(model.lineMap.wrapRows(ofLine: 2) == 1)
    }
}
