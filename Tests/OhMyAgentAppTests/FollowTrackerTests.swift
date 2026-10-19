// @author ixxxxoooo
// FollowTracker 测试:语义与 FollowState 一致;逐帧滚动不触发观察通知,只有 pinned/unseen/hasActivity 真变化才通知。

import ChatKit
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import OhMyAgentApp

/// 跨并发边界记录「是否收到通知」的标记。
private final class FiredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
@Suite("会话流跟随观察包装")
struct FollowTrackerTests {
    /// 在追踪读取三个公开属性期间执行 `body`,返回是否收到变更通知。
    private func notified(_ tracker: FollowTracker, _ body: () -> Void) -> Bool {
        let fired = FiredFlag()
        withObservationTracking {
            _ = tracker.pinned; _ = tracker.unseen; _ = tracker.hasActivity
        } onChange: { fired.set() }
        body()
        return fired.value
    }

    @Test("贴底状态下逐帧滚动/内容增长:不触发观察通知")
    func pinnedFramesDoNotNotify() {
        let tracker = FollowTracker()
        let fired = notified(tracker) {
            for index in 0..<120 {
                let height = 2000 + CGFloat(index) * 3
                tracker.geometryChanged(offsetY: height - 600, contentHeight: height, containerHeight: 600, userScrolling: false, entryCount: 10)
            }
        }
        #expect(!fired)
        #expect(tracker.pinned)
    }

    @Test("用户向上滚动:放手并通知一次;放手期间继续滚动不再通知")
    func releaseNotifiesOnce() {
        let tracker = FollowTracker()
        tracker.geometryChanged(offsetY: 1400, contentHeight: 2000, containerHeight: 600, userScrolling: false, entryCount: 10)
        var fired = notified(tracker) {
            tracker.geometryChanged(offsetY: 800, contentHeight: 2000, containerHeight: 600, userScrolling: true, entryCount: 10)
        }
        #expect(fired && !tracker.pinned && tracker.showsJumpButton)
        fired = notified(tracker) {
            for offset in stride(from: 790.0, through: 300, by: -10) {
                tracker.geometryChanged(offsetY: offset, contentHeight: 2000, containerHeight: 600, userScrolling: true, entryCount: 10)
            }
        }
        #expect(!fired)
    }

    @Test("放手后新增条目:累计未读并通知;回到最新清零")
    func unseenAndJump() {
        let tracker = FollowTracker()
        tracker.geometryChanged(offsetY: 100, contentHeight: 2000, containerHeight: 600, userScrolling: true, entryCount: 10)
        #expect(!tracker.pinned)
        #expect(tracker.contentChanged(entryCount: 13, userScrolling: false) == false)
        #expect(tracker.unseen == 3 && tracker.hasActivity)
        tracker.jumpToLatest()
        #expect(tracker.pinned && tracker.unseen == 0 && !tracker.hasActivity)
    }

    @Test("与 FollowState 逐步等价")
    func equivalentToFollowState() {
        let tracker = FollowTracker()
        var state = FollowState()
        let steps: [(CGFloat, CGFloat, Bool, Int)] = [
            (1400, 2000, false, 10), (1400, 2100, false, 11), (900, 2100, true, 11), (880, 2100, false, 12), (1500, 2100, false, 12), (1550, 2100, false, 12)
        ]
        for (offset, height, scrolling, count) in steps {
            tracker.geometryChanged(offsetY: offset, contentHeight: height, containerHeight: 600, userScrolling: scrolling, entryCount: count)
            state.geometryChanged(offsetY: offset, contentHeight: height, containerHeight: 600, userScrolling: scrolling, entryCount: count)
            #expect(tracker.pinned == state.pinned && tracker.unseen == state.unseen && tracker.hasActivity == state.hasActivity)
            #expect(tracker.contentChanged(entryCount: count + 1, userScrolling: scrolling) == state.contentChanged(entryCount: count + 1, userScrolling: scrolling))
            #expect(tracker.pinned == state.pinned && tracker.unseen == state.unseen && tracker.hasActivity == state.hasActivity)
        }
    }
}
