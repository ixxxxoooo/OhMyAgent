// @author ygw
// LSP 客户端与管理器测试:用脚本化服务器(内存回环)与 /bin/cat(真实子进程分帧)验证。

import ACPKit
import Foundation
import Synchronization
import Testing
@testable import LSPKit

/// 脚本化语言服务器:记录收到的方法,按需应答,收到 didOpen/didChange 后发布诊断。
final class ScriptedLSPServer: ACPRequestHandler, @unchecked Sendable {
    private let received = Mutex<[String]>([])
    private let shutdownSeen = Mutex(false)
    private let connection: ACPConnection
    private let hangHover: Bool

    init(transport: any ACPTransport, hangHover: Bool = false) async throws {
        connection = ACPConnection(transport: transport, label: "scripted-lsp")
        self.hangHover = hangHover
        await connection.setRequestHandler(self)
        try await connection.start()
        let inbound = connection.inbound
        Task { [weak self] in
            for await event in inbound {
                guard let self, case .notification(let method, let params) = event else { continue }
                self.record(method)
                if method == "textDocument/didOpen" || method == "textDocument/didChange" {
                    await self.publishDiagnostics(params)
                }
            }
        }
    }

    var methods: [String] { received.withLock { $0 } }
    var sawShutdown: Bool { shutdownSeen.withLock { $0 } }

    private func record(_ method: String) { received.withLock { $0.append(method) } }

    private func publishDiagnostics(_ params: JSONValue?) async {
        guard let uri = params?["textDocument"]?["uri"]?.stringValue else { return }
        let version = params?["textDocument"]?["version"]?.intValue ?? 0
        await connection.notify("textDocument/publishDiagnostics", params: [
            "uri": .string(uri), "version": .int(version),
            "diagnostics": [[
                "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]],
                "severity": 2, "message": .string("示例警告 v\(version)"), "source": "scripted",
            ]],
        ])
    }

    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        record(method)
        switch method {
        case "initialize":
            return ["capabilities": ["hoverProvider": true], "serverInfo": ["name": "scripted"]]
        case "shutdown":
            shutdownSeen.withLock { $0 = true }
            return .null
        case "textDocument/hover":
            if hangHover { try await Task.sleep(for: .seconds(30)) }
            return ["contents": ["kind": "markdown", "value": .string("hover@\(params?["position"]?["line"]?.intValue ?? -1)")]]
        case "textDocument/definition":
            return [["uri": "file:///def.swift", "range": ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 9]]]]
        case "textDocument/completion":
            return ["isIncomplete": false, "items": [["label": "alpha"], ["label": "alphabet", "kind": 3]]]
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: method)
        }
    }

    /// 向客户端发起一个反向请求并返回结果(验证客户端应答)。
    func askClient(_ method: String, params: JSONValue?) async throws -> JSONValue {
        try await connection.request(method, params: params)
    }
}

/// 创建一对回环传输并在对端启动脚本化服务器。
private func makeScripted(hangHover: Bool = false) async throws -> (client: LSPClient, server: ScriptedLSPServer) {
    let (clientSide, serverSide) = LoopbackTransport.makePair()
    let server = try await ScriptedLSPServer(transport: serverSide, hangHover: hangHover)
    let client = LSPClient(transport: clientSide, rootPath: "/tmp/proj", label: "test", requestTimeout: .milliseconds(400))
    return (client, server)
}

@Suite("LSP 客户端")
struct LSPClientTests {
    @Test("握手后就绪,记录服务器名与能力")
    func handshake() async throws {
        let (client, server) = try await makeScripted()
        try await client.start()
        #expect(await client.state == .ready)
        #expect(await client.serverName == "scripted")
        #expect(await client.capabilities["hoverProvider"]?.boolValue == true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.methods.prefix(2) == ["initialize", "initialized"])
        await client.shutdown()
    }

    @Test("打开文档发布诊断;变更后版本递增并收到新诊断")
    func diagnosticsFlow() async throws {
        let (client, _) = try await makeScripted()
        try await client.start()
        let updates = await client.diagnosticUpdates()
        let uri = LSPURI.make(path: "/tmp/proj/a.swift")
        await client.didOpen(uri: uri, languageID: "swift", text: "let a = 1")
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.uri == uri)
        #expect(first?.diagnostics.first?.message == "示例警告 v1")
        #expect(first?.diagnostics.first?.effectiveSeverity == .warning)
        let version = await client.didChange(uri: uri, text: "let a = 2")
        #expect(version == 2)
        let second = await iterator.next()
        #expect(second?.diagnostics.first?.message == "示例警告 v2")
        #expect(await client.diagnostics(for: uri).count == 1)
        await client.didClose(uri: uri)
        #expect(await client.diagnostics(for: uri).isEmpty)
        #expect(await client.openDocumentCount == 0)
        await client.shutdown()
    }

    @Test("重复 didOpen 视为变更;未打开文档的 didChange 被忽略")
    func openTwice() async throws {
        let (client, server) = try await makeScripted()
        try await client.start()
        let uri = LSPURI.make(path: "/tmp/proj/b.swift")
        #expect(await client.didChange(uri: uri, text: "x") == 0)
        await client.didOpen(uri: uri, languageID: "swift", text: "a")
        #expect(await client.didOpen(uri: uri, languageID: "swift", text: "b") == 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.methods.filter { $0 == "textDocument/didOpen" }.count == 1)
        #expect(server.methods.filter { $0 == "textDocument/didChange" }.count == 1)
        await client.shutdown()
    }

    @Test("hover / 定义 / 补全")
    func queries() async throws {
        let (client, _) = try await makeScripted()
        try await client.start()
        let uri = LSPURI.make(path: "/tmp/proj/c.swift")
        await client.didOpen(uri: uri, languageID: "swift", text: "abc")
        #expect(try await client.hover(uri: uri, at: LSPPosition(line: 7, character: 1)) == "hover@7")
        let defs = try await client.definition(uri: uri, at: LSPPosition(line: 0, character: 0))
        #expect(defs.first?.uri == "file:///def.swift")
        #expect(defs.first?.range.start == LSPPosition(line: 3, character: 4))
        let items = try await client.completion(uri: uri, at: LSPPosition(line: 0, character: 1))
        #expect(items.map(\.label) == ["alpha", "alphabet"])
        await client.shutdown()
    }

    @Test("请求超时抛出 timeout,且客户端仍可继续使用")
    func timeoutThenContinue() async throws {
        let (client, _) = try await makeScripted(hangHover: true)
        try await client.start()
        let uri = LSPURI.make(path: "/tmp/proj/d.swift")
        await client.didOpen(uri: uri, languageID: "swift", text: "x")
        await #expect(throws: LSPError.timeout(method: "textDocument/hover")) {
            _ = try await client.hover(uri: uri, at: LSPPosition(line: 0, character: 0))
        }
        #expect(try await client.completion(uri: uri, at: LSPPosition(line: 0, character: 0)).count == 2)
        await client.shutdown()
    }

    @Test("未就绪时查询抛 notReady")
    func notReady() async throws {
        let (client, _) = try await makeScripted()
        await #expect(throws: LSPError.notReady) {
            _ = try await client.hover(uri: "file:///x", at: LSPPosition(line: 0, character: 0))
        }
    }

    @Test("礼貌关闭:服务器收到 shutdown 与 exit")
    func gracefulShutdown() async throws {
        let (client, server) = try await makeScripted()
        try await client.start()
        await client.shutdown()
        try await Task.sleep(for: .milliseconds(80))
        #expect(server.sawShutdown)
        #expect(server.methods.contains("exit"))
        #expect(await client.state == .closed)
    }

    @Test("服务器的反向请求得到礼貌应答(configuration 按项数返回 null)")
    func reverseRequests() async throws {
        let (client, server) = try await makeScripted()
        try await client.start()
        let config = try await server.askClient("workspace/configuration", params: ["items": [["section": "a"], ["section": "b"]]])
        #expect(config.arrayValue?.count == 2)
        let folders = try await server.askClient("workspace/workspaceFolders", params: nil)
        #expect(folders.arrayValue?.first?["uri"]?.stringValue == LSPURI.make(path: "/tmp/proj"))
        #expect((try await server.askClient("client/registerCapability", params: ["registrations": []])).isNull)
        await #expect(throws: JSONRPCError.self) { _ = try await server.askClient("custom/unknown", params: nil) }
        await client.shutdown()
    }
}

@Suite("LSP 传输")
struct LSPTransportTests {
    @Test("真实子进程:/bin/cat 回显带分帧的消息")
    func processEcho() async throws {
        let transport = LSPStdioTransport(launch: ProcessLaunch(executable: "/bin/cat"))
        let events = try transport.start()
        let body = Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{\"t\":\"中文\"}}".utf8)
        transport.send(body)
        var echoed: Data?
        for await event in events {
            if case .line(let data) = event { echoed = data; break }
        }
        transport.stop()
        #expect(echoed == body)
    }

    @Test("环境净化:剔除 OMA_*/ANTHROPIC_*/密钥类变量,保留 PATH")
    func sanitizedEnvironment() {
        let env = LSPStdioTransport.sanitizedEnvironment(extra: ["FOO": "bar"])
        #expect(env["FOO"] == "bar")
        #expect(env.keys.allSatisfy { !$0.hasPrefix("OMA_") && !$0.hasPrefix("ANTHROPIC_") && !$0.hasSuffix("_API_KEY") })
        #expect(env["PATH"] != nil)
    }
}

/// 计数的脚本化服务器工厂。
private final class FactoryProbe: Sendable {
    let started = Mutex(0)
    let servers = Mutex<[ScriptedLSPServer]>([])
}

@Suite("LSP 管理器")
struct LSPManagerTests {
    private func manager(_ probe: FactoryProbe, available: Bool = true, idle: Duration = .seconds(60)) -> LSPManager {
        LSPManager(factory: { _, _, _ in
            guard available else { return nil }
            let (clientSide, serverSide) = LoopbackTransport.makePair()
            probe.started.withLock { $0 += 1 }
            Task {
                if let server = try? await ScriptedLSPServer(transport: serverSide) { probe.servers.withLock { $0.append(server) } }
            }
            return clientSide
        }, idleTimeout: idle, failureBackoff: 0.2)
    }

    @Test("同一工作区的多个文件共享一个服务器;不支持的类型返回 unsupported")
    func sharesServer() async throws {
        let probe = FactoryProbe()
        let manager = manager(probe)
        guard case .ready(let a) = await manager.open(path: "/tmp/p/a.swift", projectRoot: "/tmp/p", text: "a"),
              case .ready(let b) = await manager.open(path: "/tmp/p/b.swift", projectRoot: "/tmp/p", text: "b") else {
            Issue.record("应成功打开")
            return
        }
        #expect(a.client === b.client)
        #expect(probe.started.withLock { $0 } == 1)
        #expect(a.languageID == "swift")
        if case .unsupported = await manager.open(path: "/tmp/p/readme.md", projectRoot: "/tmp/p", text: "") {} else { Issue.record("md 应为 unsupported") }
        await manager.shutdownAll()
    }

    @Test("并发打开只启动一次服务器")
    func concurrentOpenStartsOnce() async throws {
        let probe = FactoryProbe()
        let manager = manager(probe)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask { _ = await manager.open(path: "/tmp/p/f\(index).swift", projectRoot: "/tmp/p", text: "x") }
            }
        }
        #expect(probe.started.withLock { $0 } == 1)
        #expect(await manager.runningCount == 1)
        await manager.shutdownAll()
    }

    @Test("服务器不可用返回 unavailable")
    func unavailable() async {
        let manager = manager(FactoryProbe(), available: false)
        if case .unavailable(let kind) = await manager.open(path: "/tmp/p/a.py", projectRoot: "/tmp/p", text: "") {
            #expect(kind == .python)
        } else {
            Issue.record("应为 unavailable")
        }
    }

    @Test("空闲回收:关闭所有文档后服务器被关闭,再次打开会重新启动")
    func idleRecycle() async throws {
        let probe = FactoryProbe()
        let manager = manager(probe, idle: .milliseconds(100))
        guard case .ready(let handle) = await manager.open(path: "/tmp/p/a.swift", projectRoot: "/tmp/p", text: "a") else {
            Issue.record("应成功打开")
            return
        }
        await manager.close(handle)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await manager.runningCount == 0)
        #expect(await handle.client.state == .closed)
        guard case .ready = await manager.open(path: "/tmp/p/a.swift", projectRoot: "/tmp/p", text: "a") else {
            Issue.record("应重新启动")
            return
        }
        #expect(probe.started.withLock { $0 } == 2)
        await manager.shutdownAll()
    }

    @Test("关闭一个文档后又打开,空闲回收被取消")
    func reopenCancelsRecycle() async throws {
        let probe = FactoryProbe()
        let manager = manager(probe, idle: .milliseconds(200))
        guard case .ready(let first) = await manager.open(path: "/tmp/p/a.swift", projectRoot: "/tmp/p", text: "a") else { return }
        await manager.close(first)
        guard case .ready = await manager.open(path: "/tmp/p/b.swift", projectRoot: "/tmp/p", text: "b") else { return }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await manager.runningCount == 1)
        await manager.shutdownAll()
    }
}
