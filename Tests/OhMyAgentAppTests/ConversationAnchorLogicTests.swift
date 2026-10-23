// @author ixxxxoooo
// 对话锚点纯逻辑:提问拆分、阶梯放大、抽样、卡片对齐。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("对话锚点逻辑")
struct ConversationAnchorLogicTests {
    private func anchors(_ count: Int) -> [ConversationAnchor] {
        (0..<count).map { ConversationAnchor(id: UUID(), index: $0, number: $0 + 1, title: "q\($0)", body: "") }
    }

    @Test("拆分:首行作标题,其余作正文;空行忽略;超长截断")
    func splitText() {
        let parts = AnchorText.split("  标题  \n\n第二行\n第三行")
        #expect(parts.title == "标题")
        #expect(parts.body == "第二行\n第三行")
        #expect(AnchorText.split("   \n ") == ("", ""))
        #expect(AnchorText.split(String(repeating: "a", count: 500)).title.count == AnchorText.maxTitle)
        #expect(AnchorText.split("t\n" + String(repeating: "b", count: 500)).body.count == AnchorText.maxBody)
    }

    @Test("阶梯放大:越靠近悬停项越长越实;无悬停时当前项突出")
    func indicatorSteps() {
        let widths = (0...3).map { AnchorRailMetrics.indicator(distance: $0, isCurrent: false).width }
        #expect(widths == [26, 18, 13, 8])
        let opacities = (0...3).map { AnchorRailMetrics.indicator(distance: $0, isCurrent: false).opacity }
        #expect(opacities == opacities.sorted(by: >))
        #expect(AnchorRailMetrics.indicator(distance: nil, isCurrent: true).width > AnchorRailMetrics.indicator(distance: nil, isCurrent: false).width)
    }

    @Test("抽样:放得下不抽样;超量时步长抽样且保留当前项与顺序")
    func sampling() {
        let few = anchors(5)
        #expect(AnchorRailMetrics.sample(few, current: nil, available: 400).count == 5)
        let many = anchors(100)
        let current = many[37].id
        let shown = AnchorRailMetrics.sample(many, current: current, available: 170)
        #expect(shown.count < 100)
        #expect(shown.contains { $0.id == current })
        #expect(shown.map(\.index) == shown.map(\.index).sorted())
    }

    @Test("卡片对齐:首项贴顶、末项贴底、中间居中")
    func popoverAlignment() {
        #expect(AnchorRailMetrics.popoverAlignment(index: 0, count: 5) == .topLeading)
        #expect(AnchorRailMetrics.popoverAlignment(index: 4, count: 5) == .bottomLeading)
        #expect(AnchorRailMetrics.popoverAlignment(index: 2, count: 5) == .leading)
        #expect(AnchorRailMetrics.popoverAlignment(index: 1, count: 2) == .bottomLeading)
    }
}
