// @author ixxxxoooo
// Markdown 文字段:相邻文字块合并为一个可连续选择的文本视图。

import AppKit
import ChatKit
import Foundation
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Markdown 文字段")
struct MarkdownTextRunTests {
    @Test("相邻文字块合并为一段,代码/表格/分隔线把它们隔开")
    func segmentsSplitAtNonTextBlocks() {
        let blocks = MarkdownParser.parse("# 标题\n\n段落一\n\n- 项一\n- 项二\n\n```swift\nlet x = 1\n```\n\n结尾\n")
        let segments = MarkdownSegment.split(blocks)
        #expect(segments.count == 3)
        if case .textRun(let first) = segments[0] { #expect(first.count == 3) } else { Issue.record("首段应为文字段") }
        if case .block(.code) = segments[1] {} else { Issue.record("第二段应为代码块") }
        if case .textRun(let last) = segments[2] { #expect(last.count == 1) } else { Issue.record("末段应为文字段") }
    }

    @Test("文字段富文本包含全部文本,列表带标记,行内代码带圆角底标记")
    func builderCoversAllBlocks() {
        let blocks = MarkdownParser.parse("还没改的\n\n- 各编辑弹窗里的系统下拉 `Picker`。\n- 其他页面里约 28 处\n")
        let built = MarkdownTextRunBuilder.build(blocks).string
        #expect(built.contains("还没改的"))
        #expect(built.contains("•\t各编辑弹窗里的系统下拉"))
        #expect(built.contains("其他页面里约 28 处"))
        #expect(built.contains("Picker"))
    }

    @Test("段落内软换行不拆成多个段落")
    func softBreakStaysInParagraph() {
        let built = MarkdownTextRunBuilder.build([.paragraph("第一行\n第二行")]).string
        #expect(!built.contains("\n"))
        #expect(built.contains("\u{2028}"))
    }

    @Test("文本视图按宽度自适应高度,窄宽度更高")
    func sizeFollowsWidth() {
        let content = MarkdownTextRunBuilder.build([.paragraph(String(repeating: "很长的一段文字。", count: 30))])
        let view = MarkdownTextRepresentable.makeTextView()
        view.textStorage?.setAttributedString(content)
        let narrow = MarkdownTextRepresentable.measure(view, width: 200).height
        let wide = MarkdownTextRepresentable.measure(view, width: 600).height
        #expect(wide > 0)
        #expect(narrow > wide)
    }
}
