// @author ixxxxoooo
// ANSI 渲染单项缓存测试:参数不变复用、输出/字号变化重建。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("ANSI 渲染缓存")
struct ANSIRenderCacheTests {
    @Test("参数不变时只构造一次")
    func reuses() {
        let cache = ANSIRenderCache()
        let raw = "\u{1B}[31m红\u{1B}[0m 正常"
        let first = cache.attributed(raw, fontSize: 12, maxLines: 400)
        for _ in 0..<10 { _ = cache.attributed(raw, fontSize: 12, maxLines: 400) }
        #expect(cache.buildCount == 1)
        #expect(String(first.characters) == "红 正常")
    }

    @Test("输出、字号或行数上限变化时重建")
    func invalidates() {
        let cache = ANSIRenderCache()
        _ = cache.attributed("a", fontSize: 12, maxLines: 400)
        _ = cache.attributed("ab", fontSize: 12, maxLines: 400)
        _ = cache.attributed("ab", fontSize: 13, maxLines: 400)
        _ = cache.attributed("ab", fontSize: 13, maxLines: 100)
        #expect(cache.buildCount == 4)
    }
}
