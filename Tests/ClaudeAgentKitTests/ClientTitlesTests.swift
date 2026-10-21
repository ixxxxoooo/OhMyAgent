// @author ixxxxoooo
// 会话标题归属:客户端负责标题时(`_meta.clientTitles`),适配器不再请求 CLI 用主模型生成标题。

import ACPKit
import Foundation
import Synchronization
import Testing
@testable import ClaudeAgentKit

@Suite("客户端负责标题", .serialized)
struct ClientTitlesTests {
    /// 跑一轮对话并返回 CLI 收到的 `generate_session_title` 次数。
    private func titleRequests(meta: JSONValue?) async throws -> Int {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let count = Atomic<Int>(0)
        harness.fake.onControl { subtype, _, _ in
            if subtype == "generate_session_title" {
                count.add(1, ordering: .sequentiallyConsistent)
                return ["title": "生成的标题"]
            }
            return FakeClaudeCLI.defaultResponse(subtype)
        }
        harness.respondToPrompts(text: "这是一段足够长的助手回复,用于标题上下文")
        let (id, _) = try await harness.newSession(meta: meta)
        _ = try await harness.prompt(id, "帮我重构登录模块的错误处理")
        try await Task.sleep(for: .milliseconds(200))
        return count.load(ordering: .sequentiallyConsistent)
    }

    @Test("未声明时回合结束后请求 CLI 生成标题")
    func adapterGeneratesByDefault() async throws {
        #expect(try await titleRequests(meta: nil) == 1)
    }

    @Test("声明 clientTitles 后不再请求 CLI 生成标题")
    func clientTitlesSkipGeneration() async throws {
        #expect(try await titleRequests(meta: ["clientTitles": true]) == 0)
    }
}
