// @author ixxxxoooo
// 时间线窗口化:只取最近 N 轮、锚点跳转时按需扩窗、缓存随窗口大小失效。

import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("时间线窗口化")
struct TimelineWindowTests {
    /// 造 `turns` 轮对话:每轮一条用户消息 + 一条助手回答。
    private func store(turns: Int) -> TimelineStore {
        let store = TimelineStore()
        for index in 0..<turns {
            store.apply(.userMessageChunk(messageId: "u\(index)", content: .text("提问 \(index)")))
            store.apply(.agentMessageChunk(messageId: "a\(index)", content: .text("回答 \(index)")))
        }
        return store
    }

    @Test("轮数没超过窗口时原样返回")
    func shortConversationIsNotWindowed() {
        let items = TimelineGrouping.group(store(turns: 5).entries)
        let slice = TimelineWindow.slice(items, visibleTurns: 40)
        #expect(slice.hiddenTurns == 0)
        #expect(slice.hiddenItems == 0)
        #expect(slice.items.count == items.count)
    }

    @Test("长会话只取最近 N 轮,窗口从某一轮的用户消息开始")
    func keepsRecentTurns() {
        let items = TimelineGrouping.group(store(turns: 100).entries)
        let slice = TimelineWindow.slice(items, visibleTurns: 40)
        #expect(slice.hiddenTurns == 60)
        #expect(slice.hiddenItems == items.count - slice.items.count)
        guard case .entry(let first) = slice.items[0] else { Issue.record("窗口首项应是条目"); return }
        #expect(first.kind == .user)
        #expect(first.displayText.contains("提问 60"))
        // 末尾保持不变
        #expect(slice.items.last?.id == items.last?.id)
    }

    @Test("锚点跳转:目标在窗口外时算出需要的窗口大小,在窗口内时不需要")
    func revealComputesWindowSize() {
        let entries = store(turns: 100).entries
        let items = TimelineGrouping.group(entries)
        let users = entries.filter { $0.kind == .user }
        // 第 0 轮离末尾 100 轮,窗口至少 100
        #expect(TimelineWindow.turnsToReveal(users[0].id, in: items, visibleTurns: 40) == 100)
        // 第 70 轮在最近 30 轮内,窗口 40 已包含
        #expect(TimelineWindow.turnsToReveal(users[70].id, in: items, visibleTurns: 40) == nil)
        // 刚好在窗口之外一轮
        #expect(TimelineWindow.turnsToReveal(users[59].id, in: items, visibleTurns: 40) == 41)
        // 不存在的条目
        #expect(TimelineWindow.turnsToReveal(UUID(), in: items, visibleTurns: 40) == nil)
    }

    @Test("窗口大小至少为 1")
    func windowAtLeastOne() {
        let items = TimelineGrouping.group(store(turns: 3).entries)
        #expect(TimelineWindow.slice(items, visibleTurns: 0).hiddenTurns == 2)
    }

    @Test("缓存:窗口大小或分组变化后切片重新计算,其余复用")
    func cacheFollowsWindowAndGrouping() {
        let timeline = store(turns: 50)
        let cache = TimelineItemsCache()
        let first = cache.windowed(for: timeline, visibleTurns: 40)
        #expect(first.hiddenTurns == 10)
        #expect(cache.windowed(for: timeline, visibleTurns: 40).items.count == first.items.count)
        #expect(cache.windowed(for: timeline, visibleTurns: 45).hiddenTurns == 5)
        timeline.apply(.userMessageChunk(messageId: "u50", content: .text("提问 50")))
        #expect(cache.windowed(for: timeline, visibleTurns: 45).hiddenTurns == 6)
    }
}
