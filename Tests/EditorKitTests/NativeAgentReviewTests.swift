// @author ixxxxoooo
// 行内 Diff 审阅与 ⌘K 行内编辑的流程测试(不依赖真实模型)。

import AppKit
import DiffKit
import EditorCore
import Foundation
import Testing
@testable import EditorKit

@Suite("NativeAgentReview")
@MainActor
struct NativeAgentReviewTests {
    private func makeView(_ text: String) -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: text), language: .plain)
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    private func waitUntil(_ timeoutMs: Int = 3000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition(), waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
    }

    @Test("行内审阅:展示 zone 与新增底色,清除后还原")
    func reviewShowAndClear() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\nd\ne\nf"
        let view = makeView(new)
        let diff = LineDiff.diff(old: old, new: new)
        var decided: [Int] = []
        view.inlineReview.show(diff: diff, title: { _ in "Agent" }, actions: [NativeDiffAction(title: "保留") { decided.append($0) }])
        #expect(view.inlineReview.isShowing)
        #expect(view.inlineReview.hunkCount == diff.hunks.count)
        #expect(!view.model.zones.isEmpty)
        #expect(view.model.decorations.items.contains { $0.kind == .agentAdded })
        // 头条 zone 高度含块头条;已删除行 zone 高度含删除行数。
        #expect(view.model.zones.allSatisfy { $0.height >= Double(NativeDiffZoneView.headerHeight) })
        view.inlineReview.clear()
        #expect(!view.inlineReview.isShowing)
        #expect(view.model.zones.isEmpty)
        #expect(!view.model.decorations.items.contains { $0.kind == .agentAdded })
        #expect(decided.isEmpty)
    }

    @Test("行内审阅:只展示待审阅的块")
    func reviewPendingOnly() {
        var old = (0..<40).map { "行\($0)" }, new = old
        new[2] = "改A"
        new[35] = "改B"
        old.append("")
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n") + "\n")
        #expect(diff.hunks.count == 2)
        let view = makeView(new.joined(separator: "\n") + "\n")
        view.inlineReview.show(diff: diff, pending: [diff.hunks[1].id], title: { _ in "x" }, actions: [])
        #expect(view.inlineReview.hunkCount == 1)
        #expect(view.inlineReview.hunkLines[diff.hunks[0].id] == nil)
    }

    @Test("⌘K:生成 → 审阅 → 拒绝恢复原文")
    func inlineEditReject() async {
        let original = "let a = 1\nlet b = 2\nlet c = 3\n"
        let view = makeView(original)
        view.inlineEdit.generate = { instruction, selected, _, _ in
            #expect(instruction == "改名")
            #expect(selected == "let b = 2")
            return "let bee = 2"
        }
        view.model.setSelections(SelectionSet([Selection(anchor: 10, head: 14)]))   // 选中第二行的一部分
        view.inlineEdit.debugRun("改名")
        #expect(view.inlineEdit.phase == .generating)
        await waitUntil { view.inlineEdit.phase == .reviewing }
        #expect(view.inlineEdit.phase == .reviewing)
        #expect(view.model.document.text() == "let a = 1\nlet bee = 2\nlet c = 3\n")
        #expect(view.inlineReview.isShowing)
        view.inlineEdit.reject()
        #expect(view.inlineEdit.phase == .idle)
        #expect(view.model.document.text() == original)
        #expect(!view.inlineReview.isShowing)
    }

    @Test("⌘K:接受保留修改;失败回到输入阶段")
    func inlineEditAcceptAndFail() async {
        let view = makeView("x\ny\nz")
        view.inlineEdit.generate = { _, selected, _, _ in selected.uppercased() }
        view.model.setSelections(SelectionSet(caret: 2))
        view.inlineEdit.debugRun("大写")
        await waitUntil { view.inlineEdit.phase == .reviewing }
        view.inlineEdit.accept()
        #expect(view.model.document.text() == "x\nY\nz")
        #expect(view.inlineEdit.phase == .idle)

        struct Boom: Error {}
        view.inlineEdit.generate = { _, _, _, _ in throw Boom() }
        view.inlineEdit.debugRun("失败")
        await waitUntil { view.inlineEdit.phase == .prompting }
        #expect(view.inlineEdit.phase == .prompting)
        view.inlineEdit.cancel()
        #expect(view.inlineEdit.phase == .idle)
        #expect(view.model.document.text() == "x\nY\nz")
    }

    @Test("⌘K:审阅期间继续编辑视为接受")
    func inlineEditEditDuringReview() async {
        let view = makeView("one\ntwo")
        view.inlineEdit.generate = { _, _, _, _ in "ONE" }
        view.model.setSelections(SelectionSet(caret: 0))
        view.inlineEdit.debugRun("大写")
        await waitUntil { view.inlineEdit.phase == .reviewing }
        view.model.insertText("!")
        #expect(view.inlineEdit.phase == .idle)
        #expect(!view.inlineReview.isShowing)
    }
}
