// @author ixxxxoooo
import ACPKit
import Foundation
import Testing
@testable import ChatKit

/// Agent 错误翻译测试。
@Suite struct AgentErrorHintsTests {
    @Test func promptRenderingFailedHasHint() {
        let error = JSONRPCError(code: -32603, message: "Internal error: Upstream request failed: [prompt_rendering_failed] The request could not be rendered")
        #expect(AgentErrorHints.message(for: error)?.contains("新建对话") == true)
    }

    @Test func unknownErrorHasNoHint() {
        #expect(AgentErrorHints.message(for: JSONRPCError(code: -1, message: "boom")) == nil)
    }

    @Test func rpcErrorDescriptionIsMessage() {
        let error = JSONRPCError(code: -32603, message: "具体原因")
        #expect(error.localizedDescription == "具体原因")
    }
}
