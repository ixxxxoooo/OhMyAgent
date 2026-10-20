// @author ixxxxoooo
// 场景测试脚手架:客户端 ⇄ `ClaudeAcpAgent` ⇄ 假 `claude`,全程内存传输,不依赖真实模型或网络。

import ACPKit
import Foundation
@testable import ClaudeAgentKit

/// 记录收到的 `session/update` 并支持等待条件。
actor UpdateLog {
    private(set) var items: [(sessionId: String, update: JSONValue)] = []

    func add(_ sessionId: String, _ update: JSONValue) { items.append((sessionId, update)) }

    var updates: [JSONValue] { items.map(\.update) }

    func kinds() -> [String] { items.compactMap { $0.update["sessionUpdate"]?.stringValue } }

    /// 等到出现满足条件的更新(超时返回 nil)。
    func wait(timeout: Double = 5, _ predicate: @Sendable (JSONValue) -> Bool) async -> JSONValue? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let hit = items.first(where: { predicate($0.update) }) { return hit.update }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func all(_ kind: String) -> [JSONValue] { updates.filter { $0["sessionUpdate"]?.stringValue == kind } }
}

/// 假启动器:每次都交出同一个假 CLI 的传输,并记录启动选项。
final class FakeLauncher: ClaudeProcessLauncher, @unchecked Sendable {
    let fake: FakeClaudeCLI
    private let lock = NSLock()
    private var launched: [ClaudeCLIOptions] = []

    init(_ fake: FakeClaudeCLI) { self.fake = fake }

    var options: [ClaudeCLIOptions] { lock.withLock { launched } }

    func makeTransport(for options: ClaudeCLIOptions) -> any ACPTransport {
        lock.withLock { launched.append(options) }
        return fake.transport
    }
}

/// 客户端侧:回应反向请求(权限、征询),并收集更新。
final class TestClient: ACPRequestHandler, @unchecked Sendable {
    let log = UpdateLog()
    private let lock = NSLock()
    private var permissionHandler: @Sendable (JSONValue) -> JSONValue = { _ in ["outcome": ["outcome": "cancelled"]] }
    private var elicitationHandler: @Sendable (JSONValue) -> JSONValue = { _ in ["action": "cancel"] }
    private var requests: [(String, JSONValue)] = []

    func onPermission(_ handler: @escaping @Sendable (JSONValue) -> JSONValue) { lock.withLock { permissionHandler = handler } }
    func onElicitation(_ handler: @escaping @Sendable (JSONValue) -> JSONValue) { lock.withLock { elicitationHandler = handler } }
    var received: [(String, JSONValue)] { lock.withLock { requests } }

    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let p = params ?? .null
        let (permission, elicitation) = lock.withLock { () -> (@Sendable (JSONValue) -> JSONValue, @Sendable (JSONValue) -> JSONValue) in
            requests.append((method, p))
            return (permissionHandler, elicitationHandler)
        }
        switch method {
        case "session/request_permission": return permission(p)
        case "elicitation/create": return elicitation(p)
        default: throw JSONRPCError(code: JSONRPCError.methodNotFound, message: method)
        }
    }
}

/// 完整脚手架。
final class AgentHarness: @unchecked Sendable {
    let fake = FakeClaudeCLI()
    let launcher: FakeLauncher
    let client: ACPConnection
    let testClient = TestClient()
    let agent: ClaudeAcpAgent
    let configDirectory: URL
    let agentStore: TranscriptStore
    let cwd: URL
    private var pump: Task<Void, Never>?

    var log: UpdateLog { testClient.log }

    /// 创建并完成 `initialize`。
    /// - Parameters:
    ///   - capabilities: 客户端能力
    ///   - grace: 取消后强制收尾的等待秒数
    static func make(capabilities: JSONValue = ["elicitation": ["form": .object([:])], "_meta": ["terminal_output": true]], grace: Double = 0.3) async throws -> AgentHarness {
        let harness = try AgentHarness(grace: grace)
        try await harness.start(capabilities: capabilities)
        return harness
    }

    private init(grace: Double) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-claudeagent-\(UUID().uuidString)", isDirectory: true)
        configDirectory = root.appendingPathComponent("config", isDirectory: true)
        cwd = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        launcher = FakeLauncher(fake)
        agentStore = TranscriptStore(configDirectory: configDirectory)
        let (clientTransport, agentTransport) = LoopbackTransport.makePair()
        client = ACPConnection(transport: clientTransport, label: "test-client")
        let config = ClaudeAgentConfig(executable: "/usr/bin/true", configDirectory: configDirectory, launcher: launcher, version: "9.9.9", managedSettingsPath: root.appendingPathComponent("none.json").path, cancelGraceSeconds: grace)
        agent = ClaudeAcpAgent(connection: ACPConnection(transport: agentTransport, label: "test-agent"), config: config)
    }

    private func start(capabilities: JSONValue) async throws {
        try fake.start()
        try await agent.start()
        await client.setRequestHandler(testClient)
        try await client.start()
        let inbound = client.inbound
        let log = testClient.log
        pump = Task {
            for await item in inbound {
                if case .notification(let method, let params) = item, method == "session/update", let sessionId = params?["sessionId"]?.stringValue, let update = params?["update"] {
                    await log.add(sessionId, update)
                }
            }
        }
        _ = try await client.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": capabilities])
    }

    /// 新建会话并返回其 ID。
    func newSession(meta: JSONValue? = nil) async throws -> (id: String, response: JSONValue) {
        var params: [String: JSONValue] = ["cwd": .string(cwd.path), "mcpServers": []]
        if let meta { params["_meta"] = meta }
        let response = try await client.request("session/new", params: .object(params))
        return (response["sessionId"]?.stringValue ?? "", response)
    }

    /// 让假 CLI 对每条用户消息回一段标准回合:回显 → 助手文本 → 结果 → idle。
    func respondToPrompts(text: String = "你好,我是 Claude", usageOutput: Int = 5) {
        let fake = self.fake
        fake.onUser { message in
            let uuid = message["uuid"]?.stringValue ?? ""
            fake.emit(["type": "system", "subtype": "session_state_changed", "state": "running"])
            fake.emit(["type": "user", "uuid": .string(uuid), "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "hi"]]], "parent_tool_use_id": .null])
            fake.emit(["type": "assistant", "uuid": "a1", "message": ["id": "m1", "role": "assistant", "model": "claude-opus-4-7", "content": [["type": "text", "text": .string(text)]],
                                                                       "usage": ["input_tokens": 10, "output_tokens": .int(usageOutput)], "stop_reason": "end_turn"], "parent_tool_use_id": .null])
            fake.emit(FakeClaudeCLI.result(text: text, uuids: [uuid]))
            fake.emit(["type": "system", "subtype": "session_state_changed", "state": "idle"])
        }
    }

    /// 发送一次提示。
    func prompt(_ id: String, _ text: String) async throws -> JSONValue {
        try await client.request("session/prompt", params: ["sessionId": .string(id), "prompt": [["type": "text", "text": .string(text)]]])
    }

    func shutdown() async {
        pump?.cancel()
        await agent.shutdown()
        try? FileManager.default.removeItem(at: configDirectory.deletingLastPathComponent())
    }
}
