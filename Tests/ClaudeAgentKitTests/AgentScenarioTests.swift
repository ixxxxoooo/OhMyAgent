// @author ixxxxoooo
// 适配器场景测试:握手、建会话、提示回合、权限、征询、取消、模式与配置、历史列表与回放。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

@Suite("适配器场景", .serialized)
struct AgentScenarioTests {
    @Test("initialize 宣告能力、引导与版本")
    func initializeCapabilities() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let result = try await harness.client.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": .object([:])])
        #expect(result["protocolVersion"]?.intValue == 1)
        #expect(result["agentInfo"]?["version"]?.stringValue == "9.9.9")
        #expect(result["_meta"]?["steering"]?["supported"]?.boolValue == true)
        #expect(result["agentCapabilities"]?["loadSession"]?.boolValue == true)
        #expect(result["agentCapabilities"]?["auth"]?["logout"] != nil)
        for key in ["close", "delete", "fork", "list", "resume", "additionalDirectories"] {
            #expect(result["agentCapabilities"]?["sessionCapabilities"]?[key] != nil)
        }
    }

    @Test("session/new 返回模式、模型与配置选项,并以 --session-id 启动")
    func newSession() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, response) = try await harness.newSession()
        #expect(!id.isEmpty)
        #expect(response["modes"]?["currentModeId"]?.stringValue == "default")
        let ids = (response["configOptions"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        #expect(ids.contains("mode") && ids.contains("model"))
        let options = try #require(harness.launcher.options.first)
        #expect(options.sessionId == id)
        #expect(options.resume == nil)
        #expect(options.disallowedTools.isEmpty)
        let commands = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "available_commands_update" }
        #expect(commands != nil)
    }

    @Test("不支持表单征询的客户端禁用 AskUserQuestion")
    func askDisabledWithoutElicitation() async throws {
        let harness = try await AgentHarness.make(capabilities: .object([:]))
        defer { Task { await harness.shutdown() } }
        _ = try await harness.newSession()
        #expect(harness.launcher.options.first?.disallowedTools.contains("AskUserQuestion") == true)
    }

    @Test("cwd 必须是存在的绝对目录")
    func cwdValidation() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        for bad in ["relative/path", "/definitely/not/here"] {
            await #expect(throws: JSONRPCError.self) {
                _ = try await harness.client.request("session/new", params: ["cwd": .string(bad), "mcpServers": []])
            }
        }
    }

    @Test("提示回合:文本更新、用量更新与 end_turn")
    func promptRoundTrip() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        harness.respondToPrompts()
        let response = try await harness.prompt(id, "你好")
        #expect(response["stopReason"]?.stringValue == "end_turn")
        #expect(response["usage"]?["inputTokens"] != nil || response["usage"] == nil || response["usage"]?.objectValue != nil)
        let chunk = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" }
        #expect(chunk?["content"]?["text"]?.stringValue == "你好,我是 Claude")
        #expect(await harness.log.all("usage_update").isEmpty == false)
    }

    @Test("连续两次提示各自收尾")
    func twoPrompts() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        harness.respondToPrompts()
        let first = try await harness.prompt(id, "一")
        let second = try await harness.prompt(id, "二")
        #expect(first["stopReason"]?.stringValue == "end_turn")
        #expect(second["stopReason"]?.stringValue == "end_turn")
    }

    @Test("权限请求:允许一次放行,拒绝回传 deny")
    func permissionFlow() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        let decisions = Box<[String]>(["allow-once", "reject"])
        harness.testClient.onPermission { _ in
            let next = decisions.mutate { $0.isEmpty ? "reject" : $0.removeFirst() }
            return ["outcome": ["outcome": "selected", "optionId": .string(next)]]
        }
        let fake = harness.fake
        fake.onUser { message in
            let uuid = message["uuid"]?.stringValue ?? ""
            fake.emit(["type": "user", "uuid": .string(uuid), "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "x"]]], "parent_tool_use_id": .null])
            fake.request("can_use_tool", id: "p1", ["tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "t1"])
            fake.request("can_use_tool", id: "p2", ["tool_name": "Bash", "input": ["command": "rm x"], "tool_use_id": "t2"])
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                fake.emit(FakeClaudeCLI.result(uuids: [uuid]))
                fake.emit(["type": "system", "subtype": "session_state_changed", "state": "idle"])
            }
        }
        _ = try await harness.prompt(id, "跑命令")
        let responses = fake.received.filter { $0["type"]?.stringValue == "control_response" }
        func behavior(_ requestId: String) -> String? {
            responses.first { $0.at("response", "request_id")?.stringValue == requestId }?.at("response", "response", "behavior")?.stringValue
        }
        #expect(behavior("p1") == "allow")
        #expect(behavior("p2") == "deny")
        let permissionRequests = harness.testClient.received.filter { $0.0 == "session/request_permission" }
        #expect(permissionRequests.count == 2)
        let options = permissionRequests.first?.1["options"]?.arrayValue?.compactMap { $0["optionId"]?.stringValue }
        #expect(options == ["allow-once", "reject"])
        #expect(permissionRequests.first?.1.at("toolCall", "toolCallId")?.stringValue == "t1")
        // 权限前已上报工具卡
        #expect(await harness.log.wait { $0["sessionUpdate"]?.stringValue == "tool_call" && $0["toolCallId"]?.stringValue == "t1" } != nil)
    }

    @Test("AskUserQuestion 经 elicitation/create 回填答案")
    func askUserQuestion() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        harness.testClient.onElicitation { _ in ["action": "accept", "content": ["question_0": "蓝色", "question_0_custom": "偏深"]] }
        let fake = harness.fake
        fake.onUser { message in
            let uuid = message["uuid"]?.stringValue ?? ""
            fake.emit(["type": "user", "uuid": .string(uuid), "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "x"]]], "parent_tool_use_id": .null])
            fake.request("can_use_tool", id: "q1", [
                "tool_name": "AskUserQuestion", "tool_use_id": "tq",
                "input": ["questions": [["question": "选哪种颜色?", "header": "颜色", "multiSelect": false, "options": [["label": "红色", "description": "热情"], ["label": "蓝色", "description": "冷静"]]]]],
            ])
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                fake.emit(FakeClaudeCLI.result(uuids: [uuid]))
                fake.emit(["type": "system", "subtype": "session_state_changed", "state": "idle"])
            }
        }
        _ = try await harness.prompt(id, "问我")
        let response = fake.received.first { $0["type"]?.stringValue == "control_response" && $0.at("response", "request_id")?.stringValue == "q1" }
        let body = response?.at("response", "response")
        #expect(body?["behavior"]?.stringValue == "allow")
        #expect(body?.at("updatedInput", "answers", "选哪种颜色?")?.stringValue == "蓝色")
        #expect(body?.at("updatedInput", "annotations", "选哪种颜色?", "notes")?.stringValue == "偏深")
        let request = harness.testClient.received.first { $0.0 == "elicitation/create" }?.1
        #expect(request?["mode"]?.stringValue == "form")
        #expect(request?["message"]?.stringValue == "选哪种颜色?")
        #expect(request?["toolCallId"]?.stringValue == "tq")
    }

    @Test("取消:发出 interrupt,回合以 cancelled 收尾")
    func cancelTurn() async throws {
        let harness = try await AgentHarness.make(grace: 0.2)
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        let fake = harness.fake
        fake.onUser { message in
            let uuid = message["uuid"]?.stringValue ?? ""
            fake.emit(["type": "user", "uuid": .string(uuid), "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "x"]]], "parent_tool_use_id": .null])
        }
        let client = harness.client
        async let outcome = harness.prompt(id, "长任务")
        try await Task.sleep(for: .milliseconds(200))
        await client.notify("session/cancel", params: ["sessionId": .string(id)])
        let response = try await outcome
        #expect(response["stopReason"]?.stringValue == "cancelled")
        #expect(fake.received.contains { $0.at("request", "subtype")?.stringValue == "interrupt" })
    }

    @Test("set_mode 与 set_config_option 同步到 CLI 并返回配置")
    func modeAndConfig() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        _ = try await harness.client.request("session/set_mode", params: ["sessionId": .string(id), "modeId": "acceptEdits"])
        #expect(harness.fake.received.contains { $0.at("request", "subtype")?.stringValue == "set_permission_mode" && $0.at("request", "mode")?.stringValue == "acceptEdits" })
        let result = try await harness.client.request("session/set_config_option", params: ["sessionId": .string(id), "configId": "model", "value": "sonnet"])
        let model = result["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }
        #expect(model?["currentValue"]?.stringValue == "sonnet")
        #expect(harness.fake.received.contains { $0.at("request", "subtype")?.stringValue == "set_model" })
    }

    @Test("无效模式被拒绝")
    func invalidMode() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        await #expect(throws: JSONRPCError.self) {
            _ = try await harness.client.request("session/set_mode", params: ["sessionId": .string(id), "modeId": "nonsense"])
        }
    }

    @Test("压缩呈现为一张「Compact conversation」工具卡")
    func compaction() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        _ = try await harness.newSession()
        harness.fake.emit(["type": "system", "subtype": "status", "status": "compacting", "uuid": "c1"])
        let started = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "tool_call" && $0["toolCallId"]?.stringValue == "c1" }
        #expect(started?["title"]?.stringValue == "Compact conversation")
        #expect(started?["status"]?.stringValue == "in_progress")
        harness.fake.emit(["type": "system", "subtype": "compact_boundary", "uuid": "c1", "compact_metadata": ["trigger": "manual", "pre_tokens": 1000, "post_tokens": 200]])
        let finished = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "tool_call_update" && $0["toolCallId"]?.stringValue == "c1" && $0["status"]?.stringValue == "completed" }
        #expect(finished?["rawOutput"]?["preTokens"]?.intValue == 1000)
    }

    @Test("close 之后会话不可用,list 分页游标")
    func closeAndList() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let (id, _) = try await harness.newSession()
        _ = try await harness.client.request("session/close", params: ["sessionId": .string(id)])
        await #expect(throws: JSONRPCError.self) { _ = try await harness.prompt(id, "x") }
        let list = try await harness.client.request("session/list", params: .object([:]))
        #expect(list["sessions"]?.arrayValue != nil)
        #expect(ClaudeAcpAgent.listOffset("offset:2000") == 2000)
        #expect(ClaudeAcpAgent.listOffset("bogus") == 0)
        #expect(ClaudeAcpAgent.listOffset(nil) == 0)
    }

    @Test("未知方法返回 methodNotFound")
    func unknownMethod() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        await #expect(throws: JSONRPCError.self) { _ = try await harness.client.request("nope/nothing", params: .object([:])) }
    }
}

/// 线程安全的小盒子(测试里共享可变状态)。
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
    var current: Value { lock.withLock { value } }
}
