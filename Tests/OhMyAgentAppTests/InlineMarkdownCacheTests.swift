// @author ixxxxoooo
// 行内 Markdown 解析缓存测试:相同原文只解析一次,结果与直接解析一致。
// 每个用例使用独立的缓存实例,不受并行测试对全局缓存的影响。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("行内 Markdown 缓存")
struct InlineMarkdownCacheTests {
    @Test("同一原文重复读取只解析一次")
    func memoizes() {
        let cache = InlineMarkdownCache()
        for _ in 0..<20 { _ = cache.parsed("**粗体** 与 `code`") }
        #expect(cache.parseCount == 1)
        _ = cache.parsed("另一段")
        #expect(cache.parseCount == 2)
    }

    @Test("缓存结果的文字内容与原文解析一致")
    func sameContent() {
        let cache = InlineMarkdownCache()
        let first = cache.parsed("a *b* c").map { String($0.characters) }
        let second = cache.parsed("a *b* c").map { String($0.characters) }
        #expect(first == "a b c")
        #expect(second == first)
    }
}
