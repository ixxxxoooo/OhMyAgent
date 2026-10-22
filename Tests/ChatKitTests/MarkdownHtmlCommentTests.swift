// @author ixxxxoooo
// Markdown HTML 注释块测试:`<!-- ... -->` 渲染时整体隐藏,不影响前后块与代码围栏内的内容。

import Testing
@testable import ChatKit

@Suite("Markdown HTML 注释")
struct MarkdownHtmlCommentTests {
    @Test("多行注释(含任务框文字)整体隐藏,后续标题照常解析")
    func multilineCommentHidden() {
        let text = """
        <!--
          Thanks for contributing!

          - [x] I've completed this task
          - [ ] This task isn't completed
        -->

        ### Description

        正文
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks == [.heading(level: 3, text: "Description"), .paragraph("正文")])
    }

    @Test("单行注释隐藏,并能打断段落")
    func singleLineCommentInterruptsParagraph() {
        let blocks = MarkdownParser.parse("前文\n<!-- 备注 -->\n后文")
        #expect(blocks == [.paragraph("前文"), .paragraph("后文")])
    }

    @Test("未闭合注释一直隐藏到文末,写完 --> 后恢复(流式增量与整段解析一致)")
    func unclosedCommentStreaming() {
        let partial = MarkdownParser.parseState("# 标题\n\n<!--\n草稿")
        #expect(partial.blocks == [.heading(level: 1, text: "标题")])
        let full = "# 标题\n\n<!--\n草稿\n-->\n\n收尾"
        let next = MarkdownParser.parseState(full, continuing: partial)
        #expect(next.blocks == MarkdownParser.parse(full))
        #expect(next.blocks == [.heading(level: 1, text: "标题"), .paragraph("收尾")])
    }

    @Test("代码围栏里的注释保持原样")
    func commentInsideFenceKept() {
        let blocks = MarkdownParser.parse("```html\n<!-- keep -->\n```")
        #expect(blocks == [.code(language: "html", code: "<!-- keep -->", isClosed: true)])
    }
}
