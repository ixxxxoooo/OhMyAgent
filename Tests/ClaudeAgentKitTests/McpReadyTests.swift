// @author ixxxxoooo
// 首条消息前等待 MCP 落定:避免远程 MCP 晚连上导致第 2 轮提示缓存整段失效。

import ACPKit
import Foundation
import Synchronization
import Testing
@testable import ClaudeAgentKit

@Suite("MCP 落定等待", .serialized)
struct McpReadyTests {
    @Test("有 pending 服务器时未落定,其余状态均视为落定")
    func settledRule() {
        #expect(!ClaudeSession.mcpSettled([["name": "a", "status": "connected"], ["name": "b", "status": "pending"]]))
        #expect(ClaudeSession.mcpSettled([["name": "a", "status": "connected"], ["name": "b", "status": "failed"], ["name": "c", "status": "needs-auth"]]))
        #expect(ClaudeSession.mcpSettled([]))
    }

    @Test("首条消息等 MCP 从 pending 变为 connected 后才发给 claude")
    func firstPromptWaitsForMcp() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let polls = Atomic<Int>(0)
        let pollsAtSend = Atomic<Int>(-1)
        harness.fake.onControl { subtype, _, _ in
            guard subtype == "mcp_status" else { return FakeClaudeCLI.defaultResponse(subtype) }
            let count = polls.add(1, ordering: .sequentiallyConsistent).newValue
            return ["mcpServers": [["name": "remote", "status": .string(count >= 3 ? "connected" : "pending")]]]
        }
        let fake = harness.fake
        fake.onUser { message in
            pollsAtSend.store(polls.load(ordering: .sequentiallyConsistent), ordering: .sequentiallyConsistent)
            let uuid = message["uuid"]?.stringValue ?? ""
            fake.emit(["type": "user", "uuid": .string(uuid), "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "hi"]]], "parent_tool_use_id": .null])
            fake.emit(FakeClaudeCLI.result(text: "ok", uuids: [uuid]))
            fake.emit(["type": "system", "subtype": "session_state_changed", "state": "idle"])
        }
        let (id, _) = try await harness.newSession()
        let response = try await harness.prompt(id, "你好")
        #expect(response["stopReason"]?.stringValue == "end_turn")
        #expect(pollsAtSend.load(ordering: .sequentiallyConsistent) >= 3)
    }

    @Test("CLI 不支持 mcp_status 时不阻塞首条消息")
    func noStatusDoesNotBlock() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        harness.respondToPrompts()
        let (id, _) = try await harness.newSession()
        let started = ContinuousClock.now
        let response = try await harness.prompt(id, "你好")
        #expect(response["stopReason"]?.stringValue == "end_turn")
        #expect(ContinuousClock.now - started < .seconds(ClaudeSession.mcpReadyTimeout))
    }
}
