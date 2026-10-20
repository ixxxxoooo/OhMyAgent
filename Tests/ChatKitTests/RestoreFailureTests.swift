// @author ixxxxoooo
// 会话恢复失败的归类与中文说明。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("恢复失败归类")
struct RestoreFailureTests {
    @Test("-32002 与 Claude 的 --resume 无效 ID 都归为「找不到」")
    func notFound() {
        #expect(AgentErrorHints.classifyRestore(JSONRPCError(code: -32002, message: "Resource not found", data: nil)) == .notFound)
        let claude = JSONRPCError(
            code: -32603, message: "Internal error",
            data: .object(["details": .string("Claude Code returned an error result: Error: --resume requires a valid session ID or session title when used with --print")]))
        #expect(AgentErrorHints.classifyRestore(claude) == .notFound)
        #expect(AgentErrorHints.restoreMessage(for: claude).contains("找不到"))
    }

    @Test("进程不可用归为引擎不可用,其余归为其他")
    func others() {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "broken pipe" } }
        #expect(AgentErrorHints.classifyRestore(Boom()) == .engineUnavailable)
        #expect(AgentErrorHints.restoreMessage(for: Boom()).contains("引擎"))
        #expect(AgentErrorHints.classifyRestore(JSONRPCError(code: -32603, message: "kaboom", data: nil)) == .other)
    }
}
