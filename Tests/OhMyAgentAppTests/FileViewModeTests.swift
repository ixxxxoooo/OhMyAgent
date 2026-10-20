// @author ixxxxoooo
// 文件标签显示模式:Markdown 三态(默认所见即所得),其他类型保持两态。

import EditorKit
import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("文件显示模式", .serialized)
struct FileViewModeTests {
    private func makeStore() -> FileViewModeStore {
        let defaults = UserDefaults(suiteName: "oma-fvm-\(UUID().uuidString)") ?? .standard
        return FileViewModeStore(defaults: defaults)
    }

    @Test("Markdown 三态且默认所见即所得;其他类型两态且默认预览")
    func availableAndDefaults() {
        #expect(FileViewMode.available(for: .markdown) == [.source, .live])
        #expect(FileViewMode.available(for: .mermaid) == [.source, .preview])
        let store = makeStore()
        #expect(store.mode(for: "/a.md", kind: .markdown) == .live)
        #expect(store.mode(for: "/a.mmd", kind: .mermaid) == .preview)
    }

    @Test("所见即所得与源码都显示编辑器,阅读隐藏;只有 Markdown 的 live 启用就地渲染")
    func editorVisibilityAndMode() {
        #expect(FileViewMode.live.showsEditor && FileViewMode.source.showsEditor && !FileViewMode.preview.showsEditor)
        #expect(FileViewMode.live.markdownEditorMode(for: .markdown) == .live)
        #expect(FileViewMode.source.markdownEditorMode(for: .markdown) == .off)
        #expect(FileViewMode.live.markdownEditorMode(for: .mermaid) == .off)
    }

    @Test("选择会按类型持久化;非法存档回退默认")
    func persistence() {
        let store = makeStore()
        store.set(.source, for: .markdown)
        #expect(store.mode(for: "/b.md", kind: .markdown) == .source)
        // 旧版本给 Markdown 存过 preview:不再可用,回退到阅读(live)
        store.set(.preview, for: .markdown)
        #expect(store.mode(for: "/b.md", kind: .markdown) == .live)
        // 非 Markdown 类型不可能是 live:即使存档里有也回退默认
        store.set(.live, for: .mermaid)
        #expect(store.mode(for: "/c.mmd", kind: .mermaid) == .preview)
    }
}
