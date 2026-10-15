// @author ygw
// M7 测试:Agent 注册表、stream-json 翻译、直连 Agent(假 claude 脚本)、Bridge MCP 服务器。

import ACPKit
import Darwin
import Foundation
import Testing
@testable import AgentHost

private func tempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-m7-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

@Suite("Agent 注册表")
struct RegistryTests {
    @Test("缺失文件返回默认;保存后可读回;旧文件被备份")
    func roundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentRegistryStore(url: dir.appendingPathComponent("agents.json"))
        #expect(store.load() == AgentRegistryData())
        var data = AgentRegistryData()
        data.agents = [AgentDescriptor(id: "goose", name: "Goose", kind: .genericACP, command: "goose", args: ["acp"])]
        data.defaultAgent = "goose"
        data.mcpAgents = [AgentMCPEntry.presets[0]]
        try store.save(data)
        #expect(store.load() == data)
        data.defaultAgent = nil
        try store.save(data)
        #expect(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("oma-backup").path))
    }

    @Test("手写文件缺省字段使用默认值,损坏文件回退默认")
    func tolerantDecoding() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agents.json")
        try #"{"agents":[{"id":"x","command":"x-agent"}],"bridge":{"disabledTools":["notify"]}}"#.write(to: url, atomically: true, encoding: .utf8)
        let data = AgentRegistryStore(url: url).load()
        #expect(data.agents.first?.name == "x")
        #expect(data.agents.first?.kind == .genericACP)
        #expect(data.agents.first?.enabled == true)
        #expect(data.directFallback)
        #expect(!data.bridge.enabledTools.contains(.notify))
        try "{oops".write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentRegistryStore(url: url).load() == AgentRegistryData())
    }

    @Test("内置 Agent 恒在前;自定义同 id 不覆盖内置;默认 Agent 被禁用时回退")
    func resolution() {
        var data = AgentRegistryData()
        data.agents = [AgentDescriptor(id: "claude-code", name: "冒名", kind: .genericACP, command: "x"),
                       AgentDescriptor(id: "a", name: "A", kind: .genericACP, command: "a", enabled: false)]
        #expect(data.allAgents.map(\.id) == ["claude-code", "claude-direct", "a"])
        #expect(data.allAgents.first?.name == "Claude Code")
        data.defaultAgent = "a"
        #expect(data.resolvedDefault.id == "claude-code")
        #expect(!data.enabledAgents.contains { $0.id == "a" })
    }

    @Test("Agent-as-MCP 转换为 stdio 配置并解析 PATH")
    func mcpAgent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        chmod(tool.path, 0o755)
        let config = AgentMCPEntry.presets[0].serverConfig(path: dir.path)
        #expect(config == .stdio(name: "agent_codex", command: tool.path, args: ["mcp-server"], env: [:]))
        #expect(AgentMCPEntry.presets[1].serverConfig(path: "").json["name"]?.stringValue == "agent_claude_code_mcp")
    }
}

@Suite("stream-json 翻译")
struct TranslatorTests {
    @Test("partial 文本与思维增量输出后,完整消息不再重复")
    func noDuplicates() {
        var t = ClaudeStreamTranslator()
        _ = t.translate(json(#"{"type":"stream_event","event":{"type":"message_start"}}"#))
        let a = t.translate(json(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}}"#))
        let b = t.translate(json(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"想"}}}"#))
        let full = t.translate(json(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"想"},{"type":"text","text":"你"}]}}"#))
        #expect(a.count == 1 && b.count == 1)
        #expect(full.isEmpty)
        // 下一条没有增量的消息仍会完整输出
        let next = t.translate(json(#"{"type":"assistant","message":{"content":[{"type":"text","text":"再见"}]}}"#))
        #expect(next.count == 1)
    }

    @Test("工具调用、结果与 Edit diff、子 Agent 元数据")
    func tools() {
        var t = ClaudeStreamTranslator()
        let call = t.translate(json(#"{"type":"assistant","parent_tool_use_id":"p1","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/a.txt","old_string":"a","new_string":"b"}}]}}"#))
        guard case .update(let start) = call.first else { Issue.record("缺少 tool_call"); return }
        #expect(start["sessionUpdate"]?.stringValue == "tool_call")
        #expect(start["kind"]?.stringValue == "edit")
        #expect(start["title"]?.stringValue == "Edit a.txt")
        #expect(start["_meta"]?["claudeCode"]?["parentToolUseId"]?.stringValue == "p1")
        let done = t.translate(json(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#))
        guard case .update(let end) = done.first else { Issue.record("缺少 tool_call_update"); return }
        #expect(end["status"]?.stringValue == "completed")
        #expect(end["content"]?.arrayValue?.first?["type"]?.stringValue == "diff")
        let failed = t.translate(json(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"拒绝"}]}]}}"#))
        guard case .update(let bad) = failed.first else { return }
        #expect(bad["status"]?.stringValue == "failed")
    }

    @Test("TodoWrite 转为 plan;result 解析用量、费用与权限拒绝")
    func planAndResult() {
        var t = ClaudeStreamTranslator()
        let out = t.translate(json(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[{"content":"做 A","status":"in_progress"}]}}]}}"#))
        #expect(out.count == 2)
        guard case .update(let plan) = out.first else { return }
        #expect(plan["sessionUpdate"]?.stringValue == "plan")
        let result = t.translate(json(#"{"type":"result","subtype":"success","is_error":false,"result":"完成","total_cost_usd":0.5,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100},"permission_denials":[{"tool_name":"Bash"}]}"#))
        guard case .finished(let finished) = result.first else { Issue.record("缺少 result"); return }
        #expect(finished.usedTokens == 115)
        #expect(finished.costUSD == 0.5)
        #expect(finished.permissionDenials == ["Bash"])
        #expect(!finished.isError)
    }
}

@Suite("直连 Agent", .serialized)
struct DirectAgentTests {
    /// 创建假 claude:回放固定事件,并把参数追加记录到文件。
    private func fakeClaude(in dir: URL, argsFile: URL) throws -> String {
        let script = dir.appendingPathComponent("claude")
        let body = """
        #!/bin/sh
        echo "$@" >> "\(argsFile.path)"
        cat > /dev/null
        echo '{"type":"system","subtype":"init","session_id":"claude-sid-1"}'
        echo '{"type":"stream_event","event":{"type":"message_start"}}'
        echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}}'
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"你好","total_cost_usd":0.02,"usage":{"input_tokens":3,"output_tokens":2}}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script.path
    }

    private func connect(claude: String) async throws -> (ACPConnection, ClaudeDirectAgent) {
        let (a, b) = LoopbackTransport.makePair()
        let agent = ClaudeDirectAgent(transport: b, claudePath: claude)
        try await agent.start()
        let client = ACPConnection(transport: a)
        try await client.start()
        return (client, agent)
    }

    @Test("握手、新建会话、提示轮次产出文本与用量,第二轮使用 --resume")
    func promptAndResume() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let argsFile = dir.appendingPathComponent("args.txt")
        let (client, _) = try await connect(claude: try fakeClaude(in: dir, argsFile: argsFile))
        let initialize = try await client.request("initialize", params: ["protocolVersion": 1])
        #expect(initialize["agentInfo"]?["name"]?.stringValue == "claude-direct")
        let session = try await client.request("session/new", params: ["cwd": .string(dir.path), "mcpServers": .array([])])
        let sid = try #require(session["sessionId"]?.stringValue)

        let collector = Task { () -> [JSONValue] in
            var updates: [JSONValue] = []
            for await item in client.inbound {
                if case .notification(let method, let params) = item, method == "session/update", let update = params?["update"] { updates.append(update) }
                if case .notification(_, let params) = item, params?["update"]?["sessionUpdate"]?.stringValue == "usage_update" { break }
            }
            return updates
        }
        let reply = try await client.request("session/prompt", params: ["sessionId": .string(sid), "prompt": [["type": "text", "text": "hi"]]])
        #expect(reply["stopReason"]?.stringValue == "end_turn")
        let updates = await collector.value
        let text = updates.compactMap { $0["content"]?["text"]?.stringValue }.joined()
        #expect(text == "你好")
        #expect(updates.last?["cost"]?["amount"]?.doubleValue == 0.02)

        _ = try await client.request("session/prompt", params: ["sessionId": .string(sid), "prompt": [["type": "text", "text": "再来"]]])
        let lines = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("--session-id") && !lines[0].contains("--resume"))
        #expect(lines[1].contains("--resume claude-sid-1"))
        #expect(lines[0].contains("--permission-mode default"))
        await client.close()
    }

    @Test("模式与模型写入命令行参数;MCP 配置序列化")
    func argumentsAndMCP() {
        var session = DirectSession(cwd: "/tmp", claudeSessionId: "sid")
        session.mode = "acceptEdits"
        session.model = "opus"
        session.mcpServers = [MCPServerConfig.stdio(name: "agent_codex", command: "/bin/codex", args: ["mcp-server"], env: ["K": "V"]).json,
                              MCPServerConfig.http(name: "web", url: "https://x", headers: [:]).json]
        let args = ClaudeDirectAgent.arguments(session: session)
        #expect(args.contains("acceptEdits") && args.contains("opus"))
        let config = try! #require(args.last)
        let parsed = json(config)
        #expect(parsed["mcpServers"]?["agent_codex"]?["command"]?.stringValue == "/bin/codex")
        #expect(parsed["mcpServers"]?["agent_codex"]?["env"]?["K"]?.stringValue == "V")
        #expect(parsed["mcpServers"]?["web"]?["type"]?.stringValue == "http")
    }

    @Test("claude 不存在时给出可读错误而不是挂起")
    func missingClaude() async throws {
        let (client, _) = try await connect(claude: "/nonexistent/claude")
        _ = try await client.request("initialize", params: ["protocolVersion": 1])
        let session = try await client.request("session/new", params: ["cwd": "/tmp"])
        let reply = try await client.request("session/prompt", params: ["sessionId": .string(session["sessionId"]?.stringValue ?? ""), "prompt": [["type": "text", "text": "x"]]])
        #expect(reply["stopReason"]?.stringValue == "end_turn")
        await client.close()
    }

    @Test("prompt 文本拼接 resource_link")
    func promptText() {
        let text = ClaudeDirectAgent.promptText([["type": "text", "text": "看这个"], ["type": "resource_link", "uri": "file:///w/a.swift", "name": "a.swift"]])
        #expect(text == "看这个\n@/w/a.swift")
    }
}

/// 记录调用的 Bridge 处理器。
final class RecordingHandler: BridgeHandler, @unchecked Sendable {
    func openFile(path: String, line: Int?) async -> BridgeResult { BridgeResult("opened \(path):\(line ?? 0)") }
    func showDiff(path: String) async -> BridgeResult { BridgeResult("diff \(path)") }
    func selection() async -> BridgeResult { BridgeResult("选中的文字") }
    func notify(title: String, message: String) async -> BridgeResult { BridgeResult("notified \(title)/\(message)") }
}

@Suite("Bridge MCP 服务器", .serialized)
struct BridgeTests {
    private func call(_ text: String, enabled: Set<BridgeTool> = Set(BridgeTool.allCases)) async -> JSONValue? {
        guard let data = await BridgeServer.respond(to: Data(text.utf8), handler: RecordingHandler(), enabled: enabled) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("initialize 回显协议版本,tools/list 只列出启用的工具,通知无响应")
    func protocolBasics() async {
        let initialize = await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(initialize?["result"]?["serverInfo"]?["name"]?.stringValue == "ohmyagent")
        #expect(await call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, enabled: [.openFile, .notify])
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["open_file", "notify"])
    }

    @Test("工具调用路由到处理器,缺参数与禁用工具返回错误")
    func toolCalls() async {
        let open = await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_file","arguments":{"path":"/w/a.swift","line":12}}}"#)
        #expect(open?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "opened /w/a.swift:12")
        #expect(open?["result"]?["isError"]?.boolValue == false)
        let selection = await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_selection"}}"#)
        #expect(selection?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "选中的文字")
        let missing = await call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"open_file","arguments":{}}}"#)
        #expect(missing?["result"]?["isError"]?.boolValue == true)
        let disabled = await call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"notify","arguments":{"message":"x"}}}"#, enabled: [.openFile])
        #expect(disabled?["error"]?["code"]?.intValue == -32602)
        let unknown = await call(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
    }

    @Test("经真实 Unix socket 往返,停止后 socket 文件被清理")
    func socketRoundTrip() async throws {
        let path = BridgeServer.makeSocketPath()
        let server = BridgeServer(socketPath: path, handler: RecordingHandler())
        try server.start()
        defer { server.stop() }
        #expect(FileManager.default.fileExists(atPath: path))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (i, byte) in path.utf8.enumerated() { buffer[i] = byte } }
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(ok == 0)
        defer { close(fd) }
        let request = Data((#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"notify","arguments":{"title":"T","message":"M"}}}"# + "\n").utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        #expect(count > 0)
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(buffer[0..<max(count, 0)]))
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "notified T/M")
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("socket 路径过长被拒绝")
    func longPath() {
        let server = BridgeServer(socketPath: "/tmp/" + String(repeating: "a", count: 120), handler: RecordingHandler())
        #expect(throws: BridgeError.self) { try server.start() }
    }
}
