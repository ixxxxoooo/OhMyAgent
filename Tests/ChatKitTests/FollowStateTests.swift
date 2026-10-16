// @author ixxxxoooo
// FollowState 单元测试:贴底、放手、新消息计数、回到最新。

import Testing
@testable import ChatKit

@Suite("会话流跟随状态")
struct FollowStateTests {
    @Test("初始贴底,流式内容变化应自动滚动")
    func initialPinned() {
        var state = FollowState()
        #expect(state.pinned)
        let scroll = state.contentChanged(entryCount: 3, userScrolling: false)
        #expect(scroll)
    }

    @Test("用户正在滚动时不抢滚动位置")
    func noFightWhileUserScrolling() {
        var state = FollowState()
        let scroll = state.contentChanged(entryCount: 3, userScrolling: true)
        #expect(!scroll)
    }

    @Test("用户滚动并离开底部后放手,不再自动滚动")
    func unpinWhenUserScrollsAway() {
        var state = FollowState()
        state.geometryChanged(offsetY: 400, contentHeight: 1000, containerHeight: 500, userScrolling: true, entryCount: 5)
        #expect(!state.pinned)
        #expect(state.showsJumpButton)
        let scroll = state.contentChanged(entryCount: 5, userScrolling: false)
        #expect(!scroll)
        #expect(state.hasActivity)
    }

    @Test("内容增高造成的暂时离底不会放手")
    func contentGrowthDoesNotUnpin() {
        var state = FollowState()
        state.geometryChanged(offsetY: 500, contentHeight: 1000, containerHeight: 500, userScrolling: false, entryCount: 5)
        state.geometryChanged(offsetY: 500, contentHeight: 1200, containerHeight: 500, userScrolling: false, entryCount: 5)
        #expect(state.pinned)
    }

    @Test("内容高度不变而偏移变小视为向上滚动")
    func offsetDecreaseUnpins() {
        var state = FollowState()
        state.geometryChanged(offsetY: 500, contentHeight: 1000, containerHeight: 500, userScrolling: false, entryCount: 5)
        state.geometryChanged(offsetY: 300, contentHeight: 1000, containerHeight: 500, userScrolling: false, entryCount: 5)
        #expect(!state.pinned)
    }

    @Test("放手期间新增条目累计为新消息数")
    func unseenCounting() {
        var state = FollowState()
        state.geometryChanged(offsetY: 100, contentHeight: 1000, containerHeight: 500, userScrolling: true, entryCount: 4)
        _ = state.contentChanged(entryCount: 4, userScrolling: false)
        #expect(state.unseen == 0)
        _ = state.contentChanged(entryCount: 6, userScrolling: false)
        #expect(state.unseen == 2)
    }

    @Test("回到底部或点击回到最新后恢复贴底并清零")
    func resetOnReturn() {
        var state = FollowState()
        state.geometryChanged(offsetY: 100, contentHeight: 1000, containerHeight: 500, userScrolling: true, entryCount: 4)
        _ = state.contentChanged(entryCount: 7, userScrolling: false)
        state.geometryChanged(offsetY: 480, contentHeight: 1000, containerHeight: 500, userScrolling: true, entryCount: 7)
        #expect(state.pinned)
        #expect(state.unseen == 0)
        #expect(!state.hasActivity)

        state.geometryChanged(offsetY: 100, contentHeight: 1000, containerHeight: 500, userScrolling: true, entryCount: 7)
        _ = state.contentChanged(entryCount: 9, userScrolling: false)
        state.jumpToLatest()
        #expect(state.pinned)
        #expect(state.unseen == 0)
    }
}
