// @author ixxxxoooo
// 自动发送调试钩子:多条消息的拆分规则。

import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("自动发送钩子")
struct AutoSendHookTests {
    @Test("按 || 拆分,去空白并丢弃空项;单条消息保持不变")
    func splitMessages() {
        #expect(AutoSendHook.messages(from: "你好 || 读 README||  ||ls") == ["你好", "读 README", "ls"])
        #expect(AutoSendHook.messages(from: "单条消息") == ["单条消息"])
    }
}
