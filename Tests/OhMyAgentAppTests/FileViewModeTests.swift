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

    @Test("所有可预览类型都是源码/阅读两态,默认阅读")
    func availableAndDefaults() {
        #expect(FileViewMode.available(for: .markdown) == [.source, .preview])
        #expect(FileViewMode.available(for: .mermaid) == [.source, .preview])
        let store = makeStore()
        #expect(store.mode(for: "/a.md", kind: .markdown) == .preview)
        #expect(store.mode(for: "/a.mmd", kind: .mermaid) == .preview)
    }

    @Test("源码显示编辑器,阅读隐藏")
    func editorVisibility() {
        #expect(FileViewMode.source.showsEditor && !FileViewMode.preview.showsEditor)
    }

    @Test("选择会按类型持久化;旧存档里已移除的 live 回退默认")
    func persistence() {
        let store = makeStore()
        store.set(.source, for: .markdown)
        #expect(store.mode(for: "/b.md", kind: .markdown) == .source)
        store.set(.preview, for: .markdown)
        #expect(store.mode(for: "/b.md", kind: .markdown) == .preview)
    }
}
