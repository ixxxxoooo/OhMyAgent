// @author ixxxxoooo
// ACPKit 协议层单元测试。

import Foundation
import Testing
@testable import ACPKit

@Suite("JSON-RPC 编解码")
struct JSONRPCTests {
    @Test("请求/通知/响应/错误可互相区分")
    func parseKinds() throws {
        let request = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1,"method":"a","params":{"x":1}}"#.utf8))
        #expect(request == .request(id: .int(1), method: "a", params: ["x": 1]))
        let note = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"n"}"#.utf8))
        #expect(note == .notification(method: "n", params: nil))
        let response = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"s","result":{"ok":true}}"#.utf8))
        #expect(response == .response(id: .string("s"), result: ["ok": true]))
        let error = try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"no"}}"#.utf8))
        #expect(error == .errorResponse(id: .int(2), error: JSONRPCError(code: -32601, message: "no")))
    }

    @Test("非法输入抛出解析错误")
    func parseInvalid() {
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data("not json".utf8)) }
        #expect(throws: JSONRPCError.self) { try JSONRPCMessage.parse(Data("[1,2]".utf8)) }
    }

    @Test("序列化不含换行并可往返")
    func roundTrip() throws {
        let message = JSONRPCMessage.request(id: .int(7), method: "session/prompt", params: ["text": "a\nb"])
        let data = try message.serialized()
        #expect(!data.contains(0x0A))
        #expect(try JSONRPCMessage.parse(data) == message)
    }

    @Test("分帧器处理拆包、粘包、CRLF 与空行")
    func framing() {
        var framer = LineFramer()
        #expect(framer.push(Data("{\"a\":".utf8)).isEmpty)
        let lines = framer.push(Data("1}\n{\"b\":2}\r\n\n{\"c\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
        let rest = framer.push(Data(":3}\n".utf8))
        #expect(rest.map { String(decoding: $0, as: UTF8.self) } == ["{\"c\":3}"])
    }
}

@Suite("模型解码")
struct ModelTests {
    @Test("工具调用增量更新只覆盖出现的字段")
    func toolCallUpdate() {
        var call = ToolCall(json: ["toolCallId": "c1", "title": "读取", "kind": "read", "status": "pending"])
        #expect(call.status == .pending)
        call.apply(update: ["toolCallId": "c1", "status": "completed", "content": [["type": "diff", "path": "/a", "newText": "x"]]])
        #expect(call.title == "读取")
        #expect(call.status == .completed)
        #expect(call.content == [.diff(path: "/a", oldText: nil, newText: "x")])
    }

    @Test("未知枚举与未知更新类型不会失败")
    func forwardCompat() {
        let call = ToolCall(json: ["toolCallId": "c", "kind": "teleport", "status": "weird"])
        #expect(call.kind == .other)
        #expect(call.status == .pending)
        guard case .unknown(let kind, _) = SessionUpdate(json: ["sessionUpdate": "from_the_future"]) else {
            Issue.record("应解析为 unknown")
            return
        }
        #expect(kind == "from_the_future")
    }

    @Test("带 piAcp.notify 元数据的消息分片解析为 Agent 通知而非正文")
    func piNotifyParsing() {
        let notify = SessionUpdate(json: [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "TPS 40 tok/s"],
            "_meta": ["piAcp": ["notify": ["level": "info"]]],
        ])
        guard case .agentNotify(let level, let text) = notify else { Issue.record("应解析为 agentNotify"); return }
        #expect(level == "info")
        #expect(text == "TPS 40 tok/s")
        // 没有元数据的分片仍是助手正文
        let plain = SessionUpdate(json: ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "你好"]])
        guard case .agentMessageChunk = plain else { Issue.record("应解析为 agentMessageChunk"); return }
    }

    @Test("配置选项容忍当前值不在选项中")
    func configOptionOutsideValue() {
        let option = SessionConfigOption(json: [
            "id": "model", "name": "Model", "type": "select", "category": "model",
            "currentValue": "gateway/x",
            "options": [["value": "default", "name": "默认"]],
        ])
        #expect(option.currentDisplayName == "gateway/x")
    }

    @Test("MCP 服务器配置序列化符合 ACP 规范")
    func mcpJSON() {
        let http = MCPServerConfig.http(name: "api", url: "https://x/mcp", headers: ["Authorization": "Bearer t"])
        #expect(http.json["type"]?.stringValue == "http")
        #expect(http.json["headers"]?.arrayValue?.first?["name"]?.stringValue == "Authorization")
        let stdio = MCPServerConfig.stdio(name: "fs", command: "/bin/x", args: ["--stdio"], env: [:])
        #expect(stdio.json["type"] == nil)
    }
}

/// 测试用委托:记录权限请求并按预设选择。
final class TestDelegate: ACPClientDelegate, @unchecked Sendable {
    var permissionChoice: PermissionOutcome = .selected(optionId: "allow")
    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome { permissionChoice }
}

/// 收集事件直到满足条件。
func collect(_ client: ACPClient, until stop: @escaping @Sendable (ClientEvent) -> Bool = { _ in false }, while work: @Sendable () async throws -> Void) async throws -> [ClientEvent] {
    let events = client.events
    let task = Task { () -> [ClientEvent] in
        var out: [ClientEvent] = []
        for await event in events {
            out.append(event)
            if stop(event) { break }
        }
        return out
    }
    try await work()
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    return await task.value
}

@Suite("ACPClient + ScriptedAgent 端到端", .serialized)
struct EndToEndTests {
    func makePair(delegate: TestDelegate = TestDelegate(), delay: Int = 1) async throws -> (ACPClient, ScriptedAgent) {
        let (a, b) = LoopbackTransport.makePair()
        let agent = ScriptedAgent(transport: b, chunkDelayMillis: delay)
        try await agent.start()
        let client = ACPClient(transport: a, delegate: delegate)
        try await client.start()
        return (client, agent)
    }

    @Test("握手与会话创建")
    func handshake() async throws {
        let (client, _) = try await makePair()
        let result = try await client.initialize()
        #expect(result.agentName == "scripted-agent")
        #expect(result.capabilities.canList)
        let setup = try await client.newSession(cwd: "/tmp")
        #expect(setup.sessionId.hasPrefix("scripted-"))
        #expect(setup.configOptions.map(\.id) == ["mode", "model"])
        await client.close()
    }

    @Test("需要登录的 Agent:未认证拒绝建会话,authenticate 后放行")
    func authenticationRequired() async throws {
        let (a, b) = LoopbackTransport.makePair()
        let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1, requireAuth: true)
        try await agent.start()
        let client = ACPClient(transport: a, delegate: TestDelegate())
        try await client.start()
        let result = try await client.initialize()
        #expect(result.authMethods.map(\.id) == ["fake-login"])
        do {
            _ = try await client.newSession(cwd: "/tmp")
            Issue.record("未认证时不应创建会话")
        } catch let error as JSONRPCError {
            #expect(error.isAuthRequired)
        }
        try await client.authenticate(methodId: "fake-login")
        let setup = try await client.newSession(cwd: "/tmp")
        #expect(setup.sessionId.hasPrefix("scripted-"))
        await client.close()
    }

    @Test("isAuthRequired 识别 -32000 与登录类文案,不误伤其他错误")
    func authErrorDetection() {
        #expect(JSONRPCError(code: -32000, message: "x").isAuthRequired)
        #expect(JSONRPCError(code: 1, message: "Please log in first").isAuthRequired)
        #expect(!JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 sessionId").isAuthRequired)
    }

    @Test("流式文本与思维被分别投递且顺序正确")
    func streaming() async throws {
        let (client, _) = try await makePair()
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let events = try await collect(client) {
            let stop = try await client.prompt(sessionId: setup.sessionId, content: [.text("你好")])
            #expect(stop == .endTurn)
        }
        var thoughts = "", message = ""
        for case .sessionUpdate(_, let update) in events {
            if case .agentThoughtChunk(_, let c) = update { thoughts += c.plainText ?? "" }
            if case .agentMessageChunk(_, let c) = update { message += c.plainText ?? "" }
        }
        #expect(thoughts == "让我先想想,这个请求需要分步骤处理。")
        #expect(message.hasPrefix("你好,这是脚本化 Agent 的回复:"))
        await client.close()
    }

    @Test("工具调用经权限批准后产出 Diff")
    func toolCallWithPermission() async throws {
        let (client, _) = try await makePair()
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let events = try await collect(client) {
            _ = try await client.prompt(sessionId: setup.sessionId, content: [.text("请用 tool 修改配置")])
        }
        var call: ToolCall?
        for case .sessionUpdate(_, let update) in events {
            if case .toolCall(let c) = update { call = c }
            if case .toolCallUpdate(_, let raw) = update { call?.apply(update: raw) }
        }
        #expect(call?.status == .completed)
        #expect(call?.content == [.diff(path: "/tmp/config.json", oldText: "{\n  \"debug\": false\n}", newText: "{\n  \"debug\": true\n}")])
        await client.close()
    }

    @Test("拒绝权限后工具失败且轮次正常结束")
    func permissionRejected() async throws {
        let delegate = TestDelegate()
        delegate.permissionChoice = .selected(optionId: "reject")
        let (client, _) = try await makePair(delegate: delegate)
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let stop = try await client.prompt(sessionId: setup.sessionId, content: [.text("tool")])
        #expect(stop == .endTurn)
        await client.close()
    }

    @Test("取消中断流式轮次并返回 cancelled")
    func cancellation() async throws {
        let (client, _) = try await makePair(delay: 5)
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let sessionId = setup.sessionId
        let promptTask = Task { try await client.prompt(sessionId: sessionId, content: [.text("slow")]) }
        try await Task.sleep(for: .milliseconds(120))
        await client.cancel(sessionId: sessionId)
        let stop = try await promptTask.value
        #expect(stop == .cancelled)
        await client.close()
    }

    @Test("配置选项设置后返回最新状态")
    func setConfig() async throws {
        let (client, _) = try await makePair()
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let options = try await client.setConfigOption(sessionId: setup.sessionId, configId: "model", value: "scripted-2")
        #expect(options.first { $0.id == "model" }?.currentValue.stringValue == "scripted-2")
        await client.close()
    }

    @Test("连接关闭时挂起的请求以错误结束")
    func closeFailsPending() async throws {
        let (client, _) = try await makePair(delay: 50)
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: "/tmp")
        let sessionId = setup.sessionId
        let promptTask = Task { try await client.prompt(sessionId: sessionId, content: [.text("slow")]) }
        try await Task.sleep(for: .milliseconds(100))
        await client.close()
        await #expect(throws: (any Error).self) { try await promptTask.value }
    }
}
