// @author ixxxxoooo
// 行内 Markdown 解析缓存测试:相同原文只解析一次,结果与直接解析一致。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("行内 Markdown 缓存", .serialized)
struct InlineMarkdownCacheTests {
    @Test("同一原文重复读取只解析一次")
    func memoizes() {
        InlineMarkdownCache.reset()
        for _ in 0..<20 { _ = inlineMarkdown("**粗体** 与 `code`") }
        #expect(InlineMarkdownCache.parseCount == 1)
        _ = inlineMarkdown("另一段")
        #expect(InlineMarkdownCache.parseCount == 2)
    }

    @Test("缓存结果的文字内容与原文解析一致")
    func sameContent() {
        InlineMarkdownCache.reset()
        let first = String(inlineMarkdown("a *b* c").characters)
        let second = String(inlineMarkdown("a *b* c").characters)
        #expect(first == "a b c")
        #expect(second == first)
    }
}
