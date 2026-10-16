// @author ixxxxoooo
// 吸顶用户消息解析与顶出位移。

import CoreGraphics
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("吸顶用户消息")
struct StickyUserTests {
    /// 构造 user, assistant, tool, user, assistant 序列。
    private func sample() -> [TimelineEntry] {
        [TimelineEntry(kind: .user, text: "q1"), TimelineEntry(kind: .assistant, text: "a1"), TimelineEntry(kind: .tool),
         TimelineEntry(kind: .user, text: "q2"), TimelineEntry(kind: .assistant, text: "a2")]
    }

    @Test("顶部是回答/工具时,吸顶其上最近的用户消息,并给出下一条用户消息")
    func stickyFromBody() throws {
        let e = sample()
        let target = try #require(StickyUser.resolve(entries: e, topIndex: 2, userMinY: [:], pushZone: 80))
        #expect(target.stickyID == e[0].id && target.nextID == e[3].id)
        let later = try #require(StickyUser.resolve(entries: e, topIndex: 4, userMinY: [:], pushZone: 80))
        #expect(later.stickyID == e[3].id && later.nextID == nil)
    }

    @Test("顶部就是用户消息且完整可见:不吸顶;进入顶出区:前一条被顶出;滚过顶边:自己接管")
    func userAtTop() throws {
        let e = sample()
        #expect(StickyUser.resolve(entries: e, topIndex: 3, userMinY: [e[3].id: 300], pushZone: 80) == nil)
        let pushing = try #require(StickyUser.resolve(entries: e, topIndex: 3, userMinY: [e[3].id: 40], pushZone: 80))
        #expect(pushing.stickyID == e[0].id && pushing.nextID == e[3].id)
        let taken = try #require(StickyUser.resolve(entries: e, topIndex: 3, userMinY: [e[3].id: -5], pushZone: 80))
        #expect(taken.stickyID == e[3].id)
        // 第一条用户消息在顶部:没有可顶出的前一条
        #expect(StickyUser.resolve(entries: e, topIndex: 0, userMinY: [e[0].id: 10], pushZone: 80) == nil)
        #expect(StickyUser.resolve(entries: e, topIndex: 0, userMinY: [:], pushZone: 80) == nil)
    }

    @Test("无效下标或没有用户消息时返回 nil;运行中引导的用户消息不参与吸顶")
    func edgeCases() {
        let e = sample()
        #expect(StickyUser.resolve(entries: e, topIndex: nil, userMinY: [:], pushZone: 80) == nil)
        #expect(StickyUser.resolve(entries: e, topIndex: 99, userMinY: [:], pushZone: 80) == nil)
        #expect(StickyUser.resolve(entries: [TimelineEntry(kind: .assistant)], topIndex: 0, userMinY: [:], pushZone: 80) == nil)
        let steered = TimelineEntry(kind: .user, text: "s")
        steered.isSteered = true
        let list = [e[0], e[1], steered, e[4]]
        #expect(StickyUser.resolve(entries: list, topIndex: 3, userMinY: [:], pushZone: 80)?.stickyID == e[0].id)
    }

    @Test("顶出位移:远离时为 0,逼近时随之上移,没有位置信息时不顶出")
    func push() {
        #expect(StickyUser.pushOffset(nextMinY: 500, cardHeight: 60) == 0)
        #expect(StickyUser.pushOffset(nextMinY: 76, cardHeight: 60) == 0)
        #expect(StickyUser.pushOffset(nextMinY: 46, cardHeight: 60) == -30)
        #expect(StickyUser.pushOffset(nextMinY: -10, cardHeight: 60) == -86)
        #expect(StickyUser.pushOffset(nextMinY: nil, cardHeight: 60) == 0)
    }
}
