// @author ixxxxoooo
// 渲染缓存:Markdown 解析按内容命中,Mermaid 场景按源码命中。

import ChatKit
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("渲染缓存", .serialized)
struct RenderCachesTests {
    @Test("同一段 Markdown 第二次解析命中缓存且结果一致")
    func markdownHit() {
        MarkdownCache.reset()
        let text = "# 标题\n\n正文 **加粗**\n\n```swift\nlet a = 1\n```"
        let first = MarkdownCache.blocks(for: text)
        let second = MarkdownCache.blocks(for: text)
        #expect(first == second)
        #expect(MarkdownCache.hits == 1)
        #expect(MarkdownCache.misses == 1)
        _ = MarkdownCache.blocks(for: text + "!")
        #expect(MarkdownCache.misses == 2)
    }

    @Test("Mermaid 成功渲染后写入缓存,再次读取同步命中")
    func mermaidHit() async {
        let source = "graph TD\n  A-->B\n  B-->C-\(Int.random(in: 0..<1_000_000))"
        #expect(MermaidSceneCache.cached(source) == nil)
        let result = await renderMermaid(source)
        guard case .scene = result else { Issue.record("Mermaid 应渲染成功"); return }
        #expect(MermaidSceneCache.cached(source) != nil)
    }

    @Test("解析失败的源码不进缓存")
    func mermaidFailureNotCached() async {
        let source = "这不是 mermaid \(Int.random(in: 0..<1_000_000))"
        let result = await renderMermaid(source)
        if case .failure = result { #expect(MermaidSceneCache.cached(source) == nil) }
    }
}
