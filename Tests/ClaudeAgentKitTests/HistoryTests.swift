// @author ixxxxoooo
// 历史会话测试:列表、加载回放、恢复、分叉、删除、重命名与转录读取。

import ACPKit
import Foundation
import Testing
@testable import ClaudeAgentKit

/// 在配置目录里写一份转录。
@discardableResult
private func writeTranscript(_ harness: AgentHarness, id: String = UUID().uuidString.lowercased(), prompt: String = "帮我写个函数", answer: String = "好的,已完成") throws -> String {
    let directory = harness.configDirectory.appendingPathComponent("projects").appendingPathComponent(TranscriptStore.projectDirectoryName(for: harness.cwd.path))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let user: JSONValue = ["type": "user", "uuid": "u1", "parentUuid": .null, "sessionId": .string(id), "cwd": .string(harness.cwd.path),
                           "message": ["role": "user", "content": .string(prompt)], "timestamp": "2026-10-21T00:00:00.000Z"]
    let assistant: JSONValue = ["type": "assistant", "uuid": "a1", "parentUuid": "u1", "sessionId": .string(id), "cwd": .string(harness.cwd.path),
                                "message": ["id": "m1", "role": "assistant", "model": "claude-sonnet-4-6", "content": [["type": "text", "text": .string(answer)]], "stop_reason": "end_turn"],
                                "timestamp": "2026-10-21T00:00:01.000Z"]
    let text = [user, assistant].compactMap { $0.serialized() }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try text.write(to: directory.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    return id
}

@Suite("历史会话", .serialized)
struct HistoryTests {
    @Test("session/list 列出转录、带标题与时间,并按 cwd 过滤")
    func list() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let id = try writeTranscript(harness)
        let result = try await harness.client.request("session/list", params: ["cwd": .string(harness.cwd.path)])
        let first = try #require(result["sessions"]?.arrayValue?.first)
        #expect(first["sessionId"]?.stringValue == id)
        #expect(first["cwd"]?.stringValue == harness.cwd.path)
        #expect(first["title"]?.stringValue == "帮我写个函数")
        #expect(first["updatedAt"]?.stringValue?.hasSuffix("Z") == true)
        let other = try await harness.client.request("session/list", params: ["cwd": .string("/tmp/nowhere-\(UUID().uuidString)")])
        #expect(other["sessions"]?.arrayValue?.isEmpty == true)
    }

    @Test("session/load 回放历史并以 --resume 启动")
    func loadReplays() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let id = try writeTranscript(harness)
        let response = try await harness.client.request("session/load", params: ["sessionId": .string(id), "cwd": .string(harness.cwd.path), "mcpServers": []])
        #expect(response["modes"]?["currentModeId"]?.stringValue != nil)
        #expect(response["configOptions"]?.arrayValue?.isEmpty == false)
        let user = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "user_message_chunk" }
        #expect(user?["content"]?["text"]?.stringValue == "帮我写个函数")
        let agent = await harness.log.wait { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" }
        #expect(agent?["content"]?["text"]?.stringValue == "好的,已完成")
        let options = try #require(harness.launcher.options.first)
        #expect(options.resume == id)
        #expect(options.forkSession == false)
        // 恢复沿用转录里记录的模型(initialize 里的 sonnet 对应 claude-sonnet-4-6);CLI 自己恢复模型,不需要再 set_model
        let model = response["configOptions"]?.arrayValue?.first { $0["id"]?.stringValue == "model" }
        #expect(model?["currentValue"]?.stringValue == "sonnet")
    }

    @Test("同参数再次 resume 复用存活会话,不重启进程")
    func resumeReusesLiveSession() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let id = try writeTranscript(harness)
        let params: JSONValue = ["sessionId": .string(id), "cwd": .string(harness.cwd.path), "mcpServers": []]
        _ = try await harness.client.request("session/resume", params: params)
        _ = try await harness.client.request("session/resume", params: params)
        #expect(harness.launcher.options.count == 1)
    }

    @Test("session/fork 产生新 ID,以 --resume --fork-session --session-id 启动")
    func fork() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let id = try writeTranscript(harness)
        let response = try await harness.client.request("session/fork", params: ["sessionId": .string(id), "cwd": .string(harness.cwd.path), "mcpServers": []])
        let newId = try #require(response["sessionId"]?.stringValue)
        #expect(newId != id)
        let options = try #require(harness.launcher.options.first)
        #expect(options.resume == id)
        #expect(options.forkSession)
        #expect(options.sessionId == newId)
    }

    @Test("session/delete 删除转录文件")
    func delete() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        let id = try writeTranscript(harness)
        #expect(harness.agentStore.findTranscript(id, cwd: harness.cwd.path) != nil)
        _ = try await harness.client.request("session/delete", params: ["sessionId": .string(id), "cwd": .string(harness.cwd.path)])
        #expect(harness.agentStore.findTranscript(id, cwd: harness.cwd.path) == nil)
    }

    @Test("非法 sessionId 被拒绝(防路径穿越)")
    func invalidSessionId() async throws {
        let harness = try await AgentHarness.make()
        defer { Task { await harness.shutdown() } }
        await #expect(throws: JSONRPCError.self) {
            _ = try await harness.client.request("session/resume", params: ["sessionId": "../../etc/passwd", "cwd": .string(harness.cwd.path)])
        }
    }

    @Test("转录读取:链式还原、恢复模型、尾部信息")
    func transcriptStore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(configDirectory: root)
        let cwd = "/Users/x/proj"
        let directory = root.appendingPathComponent("projects").appendingPathComponent(TranscriptStore.projectDirectoryName(for: cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let lines = [
            #"{"type":"user","uuid":"u1","parentUuid":null,"cwd":"/Users/x/proj","message":{"role":"user","content":"一"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"二"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":"三"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"四"}]}}"#,
        ].joined(separator: "\n")
        try lines.write(to: directory.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        let messages = store.messages(sessionId: id, cwd: cwd)
        #expect(messages.count == 4)
        #expect(TranscriptStore.resumedModel(from: messages) == "claude-opus-4-7")
        #expect(TranscriptStore.projectDirectoryName(for: "/a/b.c") == "-a-b-c")
        #expect(!TranscriptStore.isValidSessionId("../x"))
        try store.rename(sessionId: id, title: "新标题", cwd: cwd)
        #expect(store.info(sessionId: id, cwd: cwd)?.summary == "新标题")
    }

    @Test("转录读取:parentUuid 链穿过 attachment 条目也不断开(真实 claude 转录的形态)")
    func chainThroughAttachments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-transcript-att-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(configDirectory: root)
        let cwd = "/Users/x/proj"
        let directory = root.appendingPathComponent("projects").appendingPathComponent(TranscriptStore.projectDirectoryName(for: cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let lines = [
            #"{"type":"attachment","uuid":"t0","parentUuid":null,"attachment":{"type":"skill_listing","content":"很长很长"}}"#,
            #"{"type":"user","uuid":"u1","parentUuid":"t0","message":{"role":"user","content":"读文件"}}"#,
            #"{"type":"attachment","uuid":"t1","parentUuid":"u1","attachment":{"type":"deferred_tools_delta"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"t1","message":{"id":"m1","role":"assistant","model":"claude-opus-4-7","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{}}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"x"}]}}"#,
            #"{"type":"attachment","uuid":"t2","parentUuid":"u2","attachment":{"type":"x"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"t2","message":{"id":"m2","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"完成"}]}}"#,
            #"{"type":"system","uuid":"s1","parentUuid":"a2","subtype":"turn_duration"}"#,
        ].joined(separator: "\n")
        try lines.write(to: directory.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        let messages = store.messages(sessionId: id, cwd: cwd)
        #expect(messages.compactMap { $0["uuid"]?.stringValue } == ["u1", "a1", "u2", "a2"])
    }
}
