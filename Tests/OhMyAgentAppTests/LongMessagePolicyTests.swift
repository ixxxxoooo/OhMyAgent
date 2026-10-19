// @author ixxxxoooo
// 用户长消息折叠:行数估算、窗口高度与展开上限。

import CoreGraphics
import Testing

@testable import OhMyAgentApp

@Suite("长消息折叠策略")
struct LongMessagePolicyTests {
    private let line: CGFloat = 20

    @Test("行数估算:显式换行与长行折行")
    func estimatedLines() {
        #expect(LongMessagePolicy.estimatedLines("") == 0)
        #expect(LongMessagePolicy.estimatedLines("你好") == 1)
        #expect(LongMessagePolicy.estimatedLines("a\nb\nc") == 3)
        #expect(LongMessagePolicy.estimatedLines(String(repeating: "x", count: LongMessagePolicy.charsPerLine * 3 + 1)) == 4)
    }

    @Test("短消息不折叠,长消息折叠")
    func likelyLong() {
        #expect(!LongMessagePolicy.isLikelyLong("一句话"))
        #expect(LongMessagePolicy.isLikelyLong(Array(repeating: "行", count: 8).joined(separator: "\n")))
    }

    @Test("窗口高度:未测量取收起高度;内容较短取内容高度;收起固定;展开有上限")
    func windowHeight() {
        let collapsed = line * CGFloat(LongMessagePolicy.collapsedLines)
        #expect(LongMessagePolicy.windowHeight(content: 0, lineHeight: line, expanded: false) == collapsed)
        #expect(LongMessagePolicy.windowHeight(content: 50, lineHeight: line, expanded: false) == 50)
        #expect(LongMessagePolicy.windowHeight(content: 1000, lineHeight: line, expanded: false) == collapsed)
        #expect(LongMessagePolicy.windowHeight(content: 1000, lineHeight: line, expanded: true) == line * CGFloat(LongMessagePolicy.expandedMaxLines))
        #expect(LongMessagePolicy.windowHeight(content: 200, lineHeight: line, expanded: true) == 200)
    }

    @Test("实测需要折叠的判定带半行余量")
    func needsCollapse() {
        let collapsed = line * CGFloat(LongMessagePolicy.collapsedLines)
        #expect(!LongMessagePolicy.needsCollapse(content: collapsed + line * 0.4, lineHeight: line))
        #expect(LongMessagePolicy.needsCollapse(content: collapsed + line, lineHeight: line))
    }

    @Test("折叠阈值带滞回:已折叠时退出阈值更低,边界附近不抖动")
    func needsCollapseHysteresis() {
        let collapsed = line * CGFloat(LongMessagePolicy.collapsedLines)
        let boundary = collapsed + line * 0.4   // 介于 0.25 与 0.5 行余量之间
        #expect(!LongMessagePolicy.needsCollapse(content: boundary, lineHeight: line, wasCollapsible: false))
        #expect(LongMessagePolicy.needsCollapse(content: boundary, lineHeight: line, wasCollapsible: true))
        #expect(!LongMessagePolicy.needsCollapse(content: collapsed, lineHeight: line, wasCollapsible: true))
    }
}
