// @author ixxxxoooo
// 查找引用的重试:语言服务索引未就绪时先返回空 → 显示「索引中」并自动重试;最终仍空提示「没有找到引用」。

import AppKit
import EditorCore
import Testing
@testable import EditorKit

@MainActor
// 串行:三个用例都改同一个静态重试间隔,并行会互相覆盖
@Suite("查找引用重试", .serialized)
struct NativeReferencesRetryTests {
    private final class Counter: @unchecked Sendable { var calls = 0 }

    private func makeView() -> OMEditorView {
        let model = NativeEditorModel(document: EditorDocument(text: "let a = 1\nlet b = a"), language: .swift)
        model.fileName = "/tmp/x.swift"
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.setFrameSize(CGSize(width: 800, height: 300))
        return view
    }

    private func popupTitle(_ view: OMEditorView) -> String? {
        view.subviews.compactMap { $0 as? NativePopupListView }.first?.rows.first?.title
    }

    private func settle(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    @Test("前两次为空:先提示索引中,第三次有结果后列出引用")
    func retriesUntilIndexed() async {
        let saved = NativeLanguageController.referenceRetryInterval
        NativeLanguageController.referenceRetryInterval = .milliseconds(40)
        defer { NativeLanguageController.referenceRetryInterval = saved }
        let view = makeView()
        let counter = Counter()
        let hit = NativeLocation(path: "/tmp/x.swift", line: 1, column: 8, preview: "let b = a")
        view.languageController.services.references = { _ in
            counter.calls += 1
            return counter.calls >= 3 ? [hit] : []
        }
        view.languageController.findReferences()
        await settle(20)
        #expect(popupTitle(view)?.contains("索引") == true, "第一次为空后应提示索引中,实际 \(popupTitle(view) ?? "无")")
        await settle(300)
        #expect(counter.calls == 3)
        #expect(popupTitle(view)?.contains("let b = a") == true, "拿到结果后应列出引用,实际 \(popupTitle(view) ?? "无")")
    }

    @Test("一直为空:重试用尽后提示没有找到引用")
    func givesUpAfterRetries() async {
        let saved = NativeLanguageController.referenceRetryInterval
        NativeLanguageController.referenceRetryInterval = .milliseconds(5)
        defer { NativeLanguageController.referenceRetryInterval = saved }
        let view = makeView()
        let counter = Counter()
        view.languageController.services.references = { _ in counter.calls += 1; return [] }
        view.languageController.findReferences()
        await settle(400)
        #expect(counter.calls == 1 + NativeLanguageController.referenceRetries)
        #expect(popupTitle(view)?.contains("没有找到引用") == true, "实际 \(popupTitle(view) ?? "无")")
    }

    @Test("重试期间移动光标会取消重试")
    func caretMoveCancelsRetry() async {
        let saved = NativeLanguageController.referenceRetryInterval
        NativeLanguageController.referenceRetryInterval = .milliseconds(60)
        defer { NativeLanguageController.referenceRetryInterval = saved }
        let view = makeView()
        let counter = Counter()
        view.languageController.services.references = { _ in counter.calls += 1; return [] }
        view.languageController.findReferences()
        await settle(20)
        view.model.setSelections(SelectionSet(caret: 4))
        await settle(400)
        #expect(counter.calls <= 2, "光标移动后不应继续重试,实际调用 \(counter.calls) 次")
    }
}
