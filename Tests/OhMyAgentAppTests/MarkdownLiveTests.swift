// @author ixxxxoooo
// Markdown 就地渲染解析层:块切分、内联片段、标记符范围、光标所在块。

import EditorKit
import Foundation
import Testing

@Suite("Markdown 就地渲染解析")
struct MarkdownLiveTests {
    private func text(_ source: String, _ range: NSRange) -> String { (source as NSString).substring(with: range) }

    @Test("块切分:标题、段落、列表、引用、围栏、表格、分隔线")
    func blocks() {
        let source = """
        # 标题

        正文第一行
        正文第二行

        - 项一
        - [x] 项二

        > 引用

        ```swift
        let a = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        """
        let layout = MarkdownLiveRenderer.layout(for: source)
        let kinds = layout.blocks.map(\.kind)
        #expect(kinds == [.heading(1), .paragraph, .list, .quote, .code(language: "swift"), .table, .rule])
        // 块范围互不重叠且升序
        for (a, b) in zip(layout.blocks, layout.blocks.dropFirst()) { #expect(NSMaxRange(a.range) <= b.range.location) }
    }

    @Test("标题标记符范围包含井号与空格")
    func headingMarker() {
        let source = "## Hello **world**\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        let block = layout.blocks[0]
        let marker = block.spans.first { $0.style == .marker }
        #expect(marker.map { text(source, $0.range) } == "## ")
        #expect(block.kind == .heading(2))
        let bold = block.spans.first { $0.style == .traits(.bold) }
        #expect(bold.map { text(source, $0.range) } == "world")
    }

    @Test("内联:加粗、斜体、嵌套、删除线、行内代码、链接")
    func inline() {
        let source = "a **b *c* d** ~~x~~ `code` [t](http://u.com)\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        let spans = layout.blocks[0].spans
        func texts(_ style: MarkdownLiveStyle) -> [String] { spans.filter { $0.style == style }.map { text(source, $0.range) } }
        #expect(texts(.traits(.bold)) == ["b ", " d"])
        #expect(texts(.traits([.bold, .italic])) == ["c"])
        #expect(texts(.traits(.strike)) == ["x"])
        #expect(texts(.inlineCode) == ["code"])
        #expect(texts(.link) == ["t"])
        #expect(texts(.linkTail) == ["](http://u.com)"])
    }

    @Test("下划线在单词中间不触发斜体")
    func snakeCase() {
        let source = "use snake_case_name here\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        #expect(!layout.blocks[0].spans.contains { $0.style == .traits(.italic) })
    }

    @Test("围栏代码:标记符、语言名与语法色")
    func fence() {
        let source = "```swift\nlet a = 1 // x\n```\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        let block = layout.blocks[0]
        #expect(block.kind == .code(language: "swift"))
        #expect(block.spans.filter { $0.style == .marker }.map { text(source, $0.range) } == ["```", "```"])
        #expect(block.spans.contains { $0.style == .dim && text(source, $0.range) == "swift" })
        let tokens = block.spans.compactMap { span -> (String, SyntaxKind)? in
            if case .codeToken(let kind) = span.style { return (text(source, span.range), kind) }
            return nil
        }
        #expect(tokens.contains { $0.0 == "let" && $0.1 == .keyword })
        #expect(tokens.contains { $0.1 == .comment })
    }

    @Test("未闭合的围栏延伸到文末")
    func unclosedFence() {
        let source = "```py\nprint(1)\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        #expect(layout.blocks.count == 1)
        #expect(layout.blocks[0].range.length == (source as NSString).length)
    }

    @Test("列表符号与任务框")
    func listAndTask() {
        let source = "- [ ] todo\n1. one\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        let spans = layout.blocks[0].spans
        #expect(spans.filter { $0.style == .listMarker }.map { text(source, $0.range) } == ["-", "1."])
        #expect(spans.contains { $0.style == .taskBox(checked: false) && text(source, $0.range) == "[ ]" })
    }

    @Test("光标所在块的查找")
    func blockLookup() {
        let source = "# A\n\npara\n"
        let layout = MarkdownLiveRenderer.layout(for: source)
        #expect(layout.blockIndex(containing: 1) == 0)
        #expect(layout.blockIndex(containing: 4) == nil) // 空行
        #expect(layout.blockIndex(containing: 6) == 1)
        #expect(layout.blockIndex(containing: (source as NSString).length) == 1)
    }

    @Test("超长文本退化为空布局;解析 300KB 在预算内")
    func performance() {
        let chunk = "## 标题\n\n段落 **加粗** 与 `code` 和 [链接](http://x.y)。\n\n- 项目一\n- 项目二\n\n"
        let big = String(repeating: chunk, count: 3_000)
        let started = ContinuousClock.now
        let layout = MarkdownLiveRenderer.layout(for: big)
        let elapsed = ContinuousClock.now - started
        #expect(!layout.blocks.isEmpty)
        #expect(elapsed < .seconds(2))
        let huge = String(repeating: "x", count: MarkdownLiveRenderer.maxLength + 1)
        #expect(MarkdownLiveRenderer.layout(for: huge).blocks.isEmpty)
    }
}
