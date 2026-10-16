// @author ixxxxoooo
// Agent 通知(pi-acp notify)与回合提前结束启发式的测试。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("Agent 通知与提前结束")
struct AgentNotifyTests {
    @Test("info 通知成为淡色独立行,不并入助手正文")
    func notifyIsMutedSeparateEntry() {
        UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showAgentNotify)
        let store = TimelineStore()
        store.apply(.agentMessageChunk(messageId: "m", content: .text("正文")))
        store.apply(.agentNotify(level: "info", text: "TPS 40 tok/s"))
        #expect(store.entries.count == 2)
        #expect(store.entries[0].kind == .assistant)
        #expect(store.entries[0].text == "正文")
        #expect(store.entries[1].kind == .notice)
        #expect(store.entries[1].isMuted)
    }

    @Test("设置隐藏后 info 通知不进入时间线,warning 仍显示")
    func hiddenByPreference() {
        UserDefaults.standard.set(false, forKey: ClientPrefs.Key.showAgentNotify)
        defer { UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showAgentNotify) }
        let store = TimelineStore()
        store.apply(.agentNotify(level: "info", text: "TPS 40 tok/s"))
        #expect(store.entries.isEmpty)
        store.apply(.agentNotify(level: "warning", text: "上下文即将耗尽"))
        #expect(store.entries.count == 1)
        #expect(!store.entries[0].isMuted)
        #expect(store.entries[0].severity == "warning")
    }

    @Test("非 Claude 的回合停在工具调用之后判为疑似提前结束")
    func truncatedHeuristics() {
        #expect(TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .tool))
        #expect(TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .thought))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .assistant))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: true, reason: .endTurn, lastKind: .tool))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .cancelled, lastKind: .tool))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: nil))
    }
}
