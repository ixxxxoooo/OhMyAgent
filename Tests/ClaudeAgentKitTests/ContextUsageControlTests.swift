// @author ixxxxoooo
// 上下文明细扩展方法:`_session/context_usage` 转发 CLI 控制请求 `get_context_usage`,不经提示回合。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

@Suite("上下文明细控制请求", .serialized)
struct ContextUsageControlTests {
    @Test("转发 get_context_usage 并裁剪为分类、总量与窗口")
    func forwardsControlRequest() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let asked = Box<[String]>([])
        harness.fake.onControl { subtype, _, _ in
            asked.mutate { $0.append(subtype) }
            guard subtype == "get_context_usage" else { return FakeClaudeCLI.defaultResponse(subtype) }
            return [
                "categories": [
                    ["id": "system_prompt", "name": "System prompt", "tokens": 2494, "color": "promptBorder", "kind": "used"],
                    ["id": "system_tools_deferred", "name": "System tools (deferred)", "tokens": 13861, "kind": "deferred"],
                    ["id": "free_space", "name": "Free space", "tokens": 937350, "kind": "free"],
                ],
                "totalTokens": 29650, "maxTokens": 1_000_000, "gridRows": [[["isFilled": true]]],
            ]
        }
        let (id, _) = try await harness.newSession()
        let result = try await harness.client.request("_session/context_usage", params: ["sessionId": .string(id)])
        #expect(asked.current.contains("get_context_usage"))
        #expect(result["totalTokens"]?.intValue == 29650)
        #expect(result["maxTokens"]?.intValue == 1_000_000)
        #expect(result["gridRows"] == nil)
        let categories = result["categories"]?.arrayValue ?? []
        #expect(categories.count == 3)
        #expect(categories.first?["name"]?.stringValue == "System prompt")
        #expect(categories.first?["color"] == nil)
        #expect(categories[1]["kind"]?.stringValue == "deferred")
    }

    @Test("未知会话返回错误")
    func unknownSession() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        await #expect(throws: JSONRPCError.self) {
            _ = try await harness.client.request("_session/context_usage", params: ["sessionId": "nope"])
        }
    }
}
