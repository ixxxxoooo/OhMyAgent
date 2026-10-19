// @author ixxxxoooo
// 吸顶状态测试:位置字典不参与观察,只有取整后的 pushOffset 与 target 变化才通知;下标表按结构修订号缓存。

import ChatKit
import CoreGraphics
import Foundation
import Observation
import Testing
@testable import OhMyAgentApp

/// 跨并发边界记录「是否收到通知」的标记。
private final class NotifyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
@Suite("吸顶状态")
struct StickyUserStateTests {
    /// user, assistant, tool, user, assistant, tool, user 序列的会话与吸顶状态。
    private func makeState() -> (state: StickyUserState, model: SessionModel, entries: [TimelineEntry]) {
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()))
        let entries = [
            TimelineEntry(kind: .user, text: "q1"), TimelineEntry(kind: .assistant, text: "a1"), TimelineEntry(kind: .tool),
            TimelineEntry(kind: .user, text: "q2"), TimelineEntry(kind: .assistant, text: "a2"), TimelineEntry(kind: .tool),
            TimelineEntry(kind: .user, text: "q3")
        ]
        model.timeline.reset(with: entries)
        let state = StickyUserState()
        state.bind(model)
        state.cardHeight = 60
        return (state, model, entries)
    }

    private func tracked(_ state: StickyUserState, _ body: () -> Void) -> Bool {
        let flag = NotifyFlag()
        withObservationTracking {
            _ = state.target; _ = state.pushOffset; _ = state.topIndex
        } onChange: { flag.set() }
        body()
        return flag.value
    }

    @Test("顶部是回答:吸顶其上最近的用户消息;下一条用户消息逼近时给出取整的顶出位移")
    func targetAndPush() throws {
        let (state, model, e) = makeState()
        defer { withExtendedLifetime(model) {} }
        state.updateVisible([e[4].id])
        let target = try #require(state.target)
        #expect(target.stickyID == e[3].id && target.nextID == e[6].id)
        #expect(state.pushOffset == 0)
        state.report(e[6].id, minY: 46.4)   // 46.4 - 8 - 60 - 8 = -29.6 → 取整 -30
        #expect(state.pushOffset == -30)
        state.report(e[6].id, minY: 600)
        #expect(state.pushOffset == 0)
    }

    @Test("无关用户行每帧上报位置:不触发观察通知")
    func irrelevantReportsDoNotNotify() {
        let (state, model, e) = makeState()
        defer { withExtendedLifetime(model) {} }
        state.updateVisible([e[4].id])
        let fired = tracked(state) {
            for index in 0..<200 { state.report(e[0].id, minY: CGFloat(index) - 1000) }
        }
        #expect(!fired)
    }

    @Test("下一条用户消息的亚像素移动:取整后不变则不通知")
    func subPixelNoNotify() {
        let (state, model, e) = makeState()
        defer { withExtendedLifetime(model) {} }
        state.updateVisible([e[4].id])
        state.report(e[6].id, minY: 46.1)
        let fired = tracked(state) {
            state.report(e[6].id, minY: 46.2)
            state.report(e[6].id, minY: 46.3)
        }
        #expect(!fired)
        #expect(state.pushOffset == -30)
    }

    @Test("顶部变化时按下标表取最靠上的可见条目,结构变化后表随之刷新")
    func indexTableRefreshes() {
        let (state, model, e) = makeState()
        state.updateVisible([e[5].id, e[2].id, e[4].id])
        #expect(state.topIndex == 2)
        #expect(state.entry(for: e[3].id)?.id == e[3].id)
        #expect(state.entry(for: UUID()) == nil)
        // 结构变化:追加用户消息 → 新条目可被查到
        model.timeline.appendUser("q4")
        let added = model.timeline.entries.last
        #expect(added != nil)
        if let added { #expect(state.entry(for: added.id)?.id == added.id) }
        // 重置时间线:旧条目查不到
        model.timeline.reset(with: [TimelineEntry(kind: .user, text: "only")])
        #expect(state.entry(for: e[3].id) == nil)
    }
}
