// @author ixxxxoooo
// 模型网关:地址解析、失败分类、可达性探测,以及发送前探测在会话中的行为。

import ACPKit
import AgentHost
import Foundation
import Network
import Testing

@testable import ChatKit

@Suite("模型网关")
struct ModelGatewayTests {
    @Test("settings.json 的 env 优先于进程环境;非法地址被忽略")
    func baseURLResolution() {
        let url = ModelGateway.baseURL(settingsEnv: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"], processEnv: ["ANTHROPIC_BASE_URL": "https://example.com"])
        #expect(url?.absoluteString == "http://127.0.0.1:3456")
        #expect(ModelGateway.baseURL(settingsEnv: [:], processEnv: ["ANTHROPIC_BASE_URL": "https://example.com"])?.host == "example.com")
        #expect(ModelGateway.baseURL(settingsEnv: ["ANTHROPIC_BASE_URL": "not a url"], processEnv: [:]) == nil)
        #expect(ModelGateway.baseURL(settingsEnv: ["ANTHROPIC_BASE_URL": "ftp://x"], processEnv: [:]) == nil)
        #expect(ModelGateway.baseURL(settingsEnv: [:], processEnv: [:]) == nil)
    }

    @Test("从家目录读取 settings.json 的 env")
    func loadSettingsEnv() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = #"{"env":{"ANTHROPIC_BASE_URL":"http://localhost:9","N":1}}"#
        try json.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let env = ModelGateway.loadSettingsEnv(home: home)
        #expect(env["ANTHROPIC_BASE_URL"] == "http://localhost:9")
        #expect(env["N"] == nil)
        #expect(ModelGateway.loadSettingsEnv(home: home.appendingPathComponent("none")).isEmpty)
    }

    @Test("失败文本被分类为可操作提示")
    func classify() {
        #expect(ModelGateway.classify("API error (attempt 1/11): undefined Connection error.")?.contains("连接失败") == true)
        #expect(ModelGateway.classify("[claude-code:unrecognized_model]")?.contains("模型") == true)
        #expect(ModelGateway.classify("HTTP 429 rate limit")?.contains("限流") == true)
        #expect(ModelGateway.classify("401 invalid api key")?.contains("鉴权") == true)
        #expect(ModelGateway.classify("一切正常") == nil)
    }

    @Test("提示不泄露路径与凭据,仅含 origin")
    func messageOrigin() throws {
        let url = try #require(URL(string: "http://user:secret@127.0.0.1:3456/v1/path?key=abc"))
        let message = ModelGateway.unreachableMessage(url: url, reason: "连接被拒绝")
        #expect(message.contains("http://127.0.0.1:3456"))
        #expect(!message.contains("secret"))
        #expect(!message.contains("key=abc"))
    }

    @Test("端口无人监听时判定为不可达")
    func probeUnreachable() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:1"))
        let status = await ModelGateway.probe(url, timeout: 2)
        guard case .unreachable = status else {
            Issue.record("应为不可达,实际 \(status)")
            return
        }
    }

    @Test("本地服务返回任意 HTTP 响应即判定为可达")
    func probeReachable() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                if case .ready = state, resumed.setOnce() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        #expect(port != 0)
        let status = await ModelGateway.probe(url, timeout: 3)
        #expect(status == .reachable(url))
    }
}

/// 一次性标志(保证 continuation 只恢复一次)。
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
@Suite("发送前网关探测(FakeAgent)")
struct GatewaySendTests {
    static func model(checker: @escaping @Sendable () async -> GatewayStatus) async throws -> SessionModel {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try SessionModelTests.fakeAgentPath())
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.gatewayChecker = checker
        model.connect()
        #expect(await SessionModelTests.wait { model.phase == .ready })
        return model
    }

    @Test("网关不可达:不发送、不产生用户消息、文本放回输入框并提示")
    func unreachableBlocksSend() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:3456"))
        let model = try await Self.model { .unreachable(url, reason: "连接被拒绝(服务未启动?)") }
        model.send("你好")
        #expect(await SessionModelTests.wait { !model.isRunning && model.draft == "你好" })
        #expect(!model.timeline.entries.contains { $0.kind == .user })
        let notice = try #require(model.timeline.entries.last { $0.kind == .notice })
        #expect(notice.isError)
        #expect(notice.text.contains("http://127.0.0.1:3456"))
        model.shutdown()
    }

    @Test("网关可达:正常发送并得到回复")
    func reachableSends() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:3456"))
        let model = try await Self.model { .reachable(url) }
        model.send("你好")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        #expect(model.timeline.entries.first?.kind == .user)
        #expect(model.draft.isEmpty)
        model.shutdown()
    }

    @Test("未配置网关:不拦截发送")
    func notConfiguredSends() async throws {
        let model = try await Self.model { .notConfigured }
        model.send("你好")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        model.shutdown()
    }
}
