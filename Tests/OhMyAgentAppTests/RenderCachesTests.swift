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

    @Test("流式追加走增量解析:结果与整段解析一致,中间态不入全文缓存,结束后的最终文本才入缓存")
    func markdownStreaming() {
        MarkdownCache.reset()
        let full = "# 标题\n\n第一段文字\n\n- 项一\n- 项二\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n结尾"
        var text = ""
        for character in full {
            text.append(character)
            #expect(MarkdownCache.blocks(for: text, streaming: true) == MarkdownParser.parse(text))
        }
        #expect(MarkdownCache.incrementalParses == full.count - 1)
        #expect(MarkdownCache.streamingReparses == 0)
        // 流式中间态不入缓存:同一中间文本再取一次仍是未命中
        let hitsBefore = MarkdownCache.hits
        _ = MarkdownCache.blocks(for: text, streaming: false)   // 最终文本:未命中并写入
        _ = MarkdownCache.blocks(for: text, streaming: false)   // 命中
        #expect(MarkdownCache.hits == hitsBefore + 1)
    }

    @Test("两条消息同时流式输出互不干扰")
    func markdownTwoStreams() {
        MarkdownCache.reset()
        let a = Array("甲消息:第一段\n\n第二段 **加粗** 内容")
        let b = Array("乙消息:- 列表\n- 另一项\n\n尾")
        var ta = "", tb = ""
        for i in 0..<max(a.count, b.count) {
            if i < a.count { ta.append(a[i]); #expect(MarkdownCache.blocks(for: ta, streaming: true) == MarkdownParser.parse(ta)) }
            if i < b.count { tb.append(b[i]); #expect(MarkdownCache.blocks(for: tb, streaming: true) == MarkdownParser.parse(tb)) }
        }
        #expect(MarkdownCache.streamingReparses == 0)
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
