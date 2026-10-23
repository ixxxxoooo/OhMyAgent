// @author ixxxxoooo
// 客户端选项(`_meta.claudeCode.options`)到 `claude` 启动参数的透传:设置来源与仅用 --mcp-config。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

@Suite("客户端启动选项透传", .serialized)
struct UserOptionsTests {
    /// 用给定 `_meta` 新建会话,返回 CLI 的启动参数。
    private func launchArguments(meta: JSONValue?) async throws -> [String] {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        _ = try await harness.newSession(meta: meta)
        return try #require(harness.launcher.options.last).arguments()
    }

    @Test("未指定时加载 user/project/local 设置,不加 --strict-mcp-config")
    func defaultsLoadAllSources() async throws {
        let args = try await launchArguments(meta: nil)
        let index = try #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[index + 1] == "user,project,local")
        #expect(!args.contains("--strict-mcp-config"))
    }

    @Test("纯文字会话的空设置来源与 strictMcpConfig 生效")
    func plainChatOptionsHonored() async throws {
        let meta: JSONValue = ["claudeCode": ["options": ["settingSources": .array([]), "strictMcpConfig": true]]]
        let args = try await launchArguments(meta: meta)
        let index = try #require(args.firstIndex(of: "--setting-sources"))
        #expect(args[index + 1] == "")
        #expect(args.contains("--strict-mcp-config"))
    }
}
