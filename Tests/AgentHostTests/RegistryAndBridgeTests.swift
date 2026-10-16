// @author ixxxxoooo
// M7 测试:Agent 注册表、Bridge MCP 服务器。

import ACPKit
import Darwin
import Foundation
import Testing
@testable import AgentHost
import ProviderProxyKit

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
        #expect(!data.bridge.enabledTools.contains(.notify))
        try "{oops".write(to: url, atomically: true, encoding: .utf8)
        #expect(AgentRegistryStore(url: url).load() == AgentRegistryData())
    }

    @Test("旧版 agents.json 含已删除的直连字段与未知 kind 时仍可读取")
    func legacyDirectFieldsTolerated() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agents.json")
        try #"{"directFallback":true,"defaultAgent":"claude-direct","agents":[{"id":"x","command":"x-agent","kind":"claudeDirect"}]}"#.write(to: url, atomically: true, encoding: .utf8)
        let data = AgentRegistryStore(url: url).load()
        #expect(data.agents.first?.kind == .genericACP)
        #expect(data.resolvedDefault.id == "claude-code")
        #expect(data.allAgents.map(\.id) == ["claude-code", "x"])
    }

    @Test("内置 Agent 恒在前;自定义同 id 不覆盖内置;默认 Agent 被禁用时回退")
    func resolution() {
        var data = AgentRegistryData()
        data.agents = [AgentDescriptor(id: "claude-code", name: "冒名", kind: .genericACP, command: "x"),
                       AgentDescriptor(id: "a", name: "A", kind: .genericACP, command: "a", enabled: false)]
        #expect(data.allAgents.map(\.id) == ["claude-code", "a"])
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

    @Test("经真实回环网关用 HTTP 往返:initialize / tools/call / 通知 / 非法方法,停止后路由消失")
    func httpRoundTrip() async throws {
        let gateway = LocalGateway()
        defer { Task { await gateway.shutdown() } }
        let server = BridgeServer(handler: RecordingHandler(), gateway: gateway)
        let url = try await server.start()
        #expect(await gateway.routeCount == 1)

        func post(_ body: String) async throws -> (Data, Int) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let (initData, initStatus) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(initStatus == 200)
        #expect(try JSONDecoder().decode(JSONValue.self, from: initData)["result"]?["serverInfo"]?["name"]?.stringValue == "ohmyagent")

        let (callData, _) = try await post(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"notify","arguments":{"title":"T","message":"M"}}}"#)
        let reply = try JSONDecoder().decode(JSONValue.self, from: callData)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "notified T/M")

        let (_, noteStatus) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(noteStatus == 202, "通知无响应体,返回 202")

        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        let (_, getResponse) = try await URLSession(configuration: .ephemeral).data(for: get)
        #expect((getResponse as? HTTPURLResponse)?.statusCode == 405)

        // 并发请求互不串扰
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let (data, _) = try await post(#"{"jsonrpc":"2.0","id":\#(index),"method":"tools/call","params":{"name":"open_file","arguments":{"path":"f\#(index)"}}}"#)
                    return try JSONDecoder().decode(JSONValue.self, from: data)["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                }
            }
            var texts: Set<String> = []
            for try await text in group { texts.insert(text) }
            #expect(texts.count == 8)
        }

        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gateway.routeCount == 0)
        let (_, goneStatus) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        #expect(goneStatus == 404)
    }
}
