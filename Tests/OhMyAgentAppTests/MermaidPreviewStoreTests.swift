// @author ixxxxoooo
// Mermaid 预览内容仓库:同源码同标识,容量有上限并淘汰最久未登记的。

import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Mermaid 预览仓库")
struct MermaidPreviewStoreTests {
    @Test("同源码得到同标识,内容可取回")
    func stableIdentity() {
        let store = MermaidPreviewStore()
        let first = store.register("graph TD; A-->B")
        let second = store.register("graph TD; A-->B")
        #expect(first == second)
        #expect(store.sources[first] == "graph TD; A-->B")
    }

    @Test("超过容量时淘汰最久未登记的源码,再次登记的会被保留")
    func evictsOldest() {
        let store = MermaidPreviewStore()
        let first = store.register("graph TD; first")
        for index in 0..<(MermaidPreviewStore.capacity - 1) { _ = store.register("graph TD; n\(index)") }
        #expect(store.sources.count == MermaidPreviewStore.capacity)
        _ = store.register("graph TD; first")        // 刷新为最近
        _ = store.register("graph TD; overflow")     // 触发淘汰:被淘汰的应是 n0 而不是 first
        #expect(store.sources.count == MermaidPreviewStore.capacity)
        #expect(store.sources[first] != nil)
        #expect(store.sources.values.contains("graph TD; n0") == false)
    }
}
