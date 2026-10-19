// @author ixxxxoooo
// Claude Code 合成用户消息(中断/拒绝/工具未完成)的识别与时间线显示测试。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("合成用户消息")
struct SyntheticUserMessageTests {
    @Test("中断文案识别为中断,普通输入不命中")
    func classify() {
        #expect(SyntheticUserMessage.classify("[Request interrupted by user]") != nil)
        #expect(SyntheticUserMessage.classify("[Request interrupted by user for tool use]") != nil)
        #expect(SyntheticUserMessage.classify("The user doesn't want to take this action right now. STOP") == .denied)
        #expect(SyntheticUserMessage.classify("[Tool call skipped: the turn was stopped]") == .hidden)
        #expect(SyntheticUserMessage.classify("帮我修复这两个问题") == nil)
    }

    @Test("中断变成淡色提示条目而不是用户气泡")
    func interruptedBecomesNotice() {
        let store = TimelineStore()
        store.apply(.userMessageChunk(messageId: "u", content: .text("帮我修复")))
        store.apply(.userMessageChunk(messageId: "u2", content: .text("[Request interrupted by user]")))
        #expect(store.entries.count == 2)
        #expect(store.entries[0].kind == .user)
        #expect(store.entries[1].kind == .notice)
        #expect(store.entries[1].severity == "interrupt")
        #expect(store.entries[1].isMuted)
    }

    @Test("工具调用未完成类说明不进入时间线")
    func hiddenNotShown() {
        let store = TimelineStore()
        store.apply(.userMessageChunk(messageId: "u", content: .text("[Tool call interrupted: the session ended]")))
        #expect(store.entries.isEmpty)
    }
}
