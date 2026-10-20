// @author ixxxxoooo
// CLI 层测试:命令行参数拼装与控制通道(请求关联、反向请求应答、取消、关闭)。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

/// 记录委托调用并返回预设应答。
private final class StubDelegate: ClaudeQueryDelegate, @unchecked Sendable {
    func canUseTool(_ request: JSONValue, requestId: String) async -> JSONValue? {
        ["behavior": "allow", "updatedInput": request["input"] ?? .null]
    }
    func hookCallback(callbackId: String, input: JSONValue, toolUseId: String?) async -> JSONValue { ["continue": true] }
    func elicitation(_ request: JSONValue) async -> JSONValue? { ["action": "decline"] }
    func userDialog(_ request: JSONValue) async -> JSONValue? { nil }
}

@Suite("CLI 参数")
struct CLIOptionsTests {
    @Test("基础参数包含 stream-json、权限工具与回放开关")
    func basicArguments() {
        let options = ClaudeCLIOptions(executable: "/bin/claude", cwd: "/tmp")
        let args = options.arguments()
        #expect(Array(args.prefix(5)) == ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"])
        #expect(args.contains("--permission-prompt-tool=stdio"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--replay-user-messages"))
    }

    @Test("模型、模式、恢复与分叉参数")
    func resumeAndFork() {
        var options = ClaudeCLIOptions(executable: "/bin/claude", cwd: "/tmp")
        options.model = "sonnet"
        options.permissionMode = "acceptEdits"
        options.resume = "abc"
        options.forkSession = true
        options.settingSources = ["user", "project", "local"]
        options.disallowedTools = ["AskUserQuestion"]
        options.tools = .preset
        options.additionalDirectories = ["/a", "/b"]
        let args = options.arguments()
        func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        #expect(value(after: "--model") == "sonnet")
        #expect(value(after: "--permission-mode") == "acceptEdits")
        #expect(value(after: "--resume") == "abc")
        #expect(args.contains("--fork-session"))
        #expect(value(after: "--setting-sources") == "user,project,local")
        #expect(value(after: "--disallowedTools") == "AskUserQuestion")
        #expect(args.contains("--tools=default"))
        #expect(args.filter { $0 == "--add-dir" }.count == 2)
    }

    @Test("设置对象序列化为 --settings JSON,备用模型与主模型相同时忽略")
    func settingsAndFallback() {
        var options = ClaudeCLIOptions(executable: "/bin/claude", cwd: "/tmp")
        options.settings = ["env": ["A": "1"]]
        options.model = "sonnet"
        options.fallbackModel = "sonnet"
        options.mcpServers = ["m": ["type": "http", "url": "http://x"]]
        let args = options.arguments()
        #expect(args.contains("--settings"))
        #expect(args.contains(#"{"env":{"A":"1"}}"#))
        #expect(!args.contains("--fallback-model"))
        #expect(args.contains("--mcp-config"))
    }

    @Test("启动环境带 SDK 入口与会话状态事件")
    func environment() {
        let env = ClaudeCLIOptions(executable: "/bin/claude", cwd: "/tmp").launchEnvironment()
        #expect(env["CLAUDE_CODE_ENTRYPOINT"] == "sdk-ts")
        #expect(env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] == "1")
    }
}

@Suite("控制通道")
struct ClaudeQueryTests {
    private func makeQuery(_ fake: FakeClaudeCLI) async throws -> ClaudeQuery {
        try fake.start()
        let query = ClaudeQuery(transport: fake.transport, delegate: StubDelegate(), label: "t")
        try await query.start()
        return query
    }

    @Test("控制请求按 request_id 关联响应")
    func controlRoundTrip() async throws {
        let fake = FakeClaudeCLI()
        fake.onControl { subtype, _, _ in subtype == "set_model" ? ["ok": true] : nil }
        let query = try await makeQuery(fake)
        let response = try await query.control("set_model", ["model": "sonnet"])
        #expect(response["ok"]?.boolValue == true)
        await query.close()
    }

    @Test("CLI 返回 error 时抛出 controlFailed")
    func controlError() async throws {
        let fake = FakeClaudeCLI()
        try fake.start()
        fake.onControl { _, _, id in
            fake.emit(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": "boom"]])
            return nil
        }
        let query = ClaudeQuery(transport: fake.transport, delegate: StubDelegate())
        try await query.start()
        do {
            try await query.control("set_model", [:])
            Issue.record("应当抛错")
        } catch let error as ClaudeQueryError {
            #expect(error.localizedDescription == "boom")
        }
        await query.close()
    }

    @Test("can_use_tool 经委托应答并带回 toolUseID")
    func canUseTool() async throws {
        let fake = FakeClaudeCLI()
        let query = try await makeQuery(fake)
        _ = query
        fake.request("can_use_tool", id: "p1", ["tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "toolu_1"])
        try await waitUntil { fake.received.contains { $0["type"]?.stringValue == "control_response" } }
        let reply = try #require(fake.received.first { $0["type"]?.stringValue == "control_response" })
        #expect(reply.at("response", "request_id")?.stringValue == "p1")
        #expect(reply.at("response", "response", "behavior")?.stringValue == "allow")
        #expect(reply.at("response", "response", "toolUseID")?.stringValue == "toolu_1")
        await query.close()
    }

    @Test("非控制消息按序进入消息流,进程退出后流结束")
    func messagesAndExit() async throws {
        let fake = FakeClaudeCLI()
        let query = try await makeQuery(fake)
        fake.emit(["type": "system", "subtype": "init"])
        fake.emit(FakeClaudeCLI.result())
        fake.exit()
        var types: [String] = []
        for await message in query.messages { types.append(message["type"]?.stringValue ?? "") }
        #expect(types == ["system", "result"])
    }

    @Test("通道关闭后挂起的控制请求以 closed 失败")
    func pendingFailsOnClose() async throws {
        let fake = FakeClaudeCLI()
        try fake.start()
        fake.onControl { _, _, _ in nil }
        let query = ClaudeQuery(transport: fake.transport, delegate: StubDelegate())
        try await query.start()
        async let result: JSONValue = query.control("never", [:])
        try await Task.sleep(for: .milliseconds(50))
        fake.exit()
        do {
            _ = try await result
            Issue.record("应当抛错")
        } catch is ClaudeQueryError {}
    }
}

/// 轮询等待条件成立(最长 3 秒)。
func waitUntil(timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { Issue.record("等待超时"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
