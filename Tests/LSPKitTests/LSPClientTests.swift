// @author ixxxxoooo
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
        case "textDocument/references":
            return [["uri": "file:///a.swift", "range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]]],
                    ["uri": "file:///b.swift", "range": ["start": ["line": 7, "character": 0], "end": ["line": 7, "character": 3]]]]
        case "textDocument/documentSymbol":
            return [["name": "Foo", "kind": 23, "range": ["start": ["line": 0, "character": 0], "end": ["line": 9, "character": 1]],
                     "selectionRange": ["start": ["line": 0, "character": 7], "end": ["line": 0, "character": 10]],
                     "children": [["name": "bar", "kind": 6, "range": ["start": ["line": 2, "character": 4], "end": ["line": 4, "character": 5]],
                                   "selectionRange": ["start": ["line": 2, "character": 9], "end": ["line": 2, "character": 12]]]]]]
        case "textDocument/rename":
            let name = params?["newName"]?.stringValue ?? ""
            return ["changes": ["file:///a.swift": [["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 7]], "newText": .string(name)]]]]
        case "textDocument/formatting":
            return [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 2]], "newText": "  "]]
        case "textDocument/signatureHelp":
            return ["signatures": [["label": "f(a: Int, b: String)", "parameters": [["label": "a: Int"], ["label": "b: String"]]]], "activeSignature": 0, "activeParameter": 1]
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

    @Test("超过工作区上限时回收最久未用且空闲的服务器,有打开文档的保留")
    func evictsOverLimit() async throws {
        let probe = FactoryProbe()
        let manager = manager(probe)
        await manager.setMaxClients(2)
        guard case .ready(let a) = await manager.open(path: "/tmp/pa/a.swift", projectRoot: "/tmp/pa", text: "a") else { Issue.record("A 应打开"); return }
        await manager.close(a)
        guard case .ready(let b) = await manager.open(path: "/tmp/pb/b.swift", projectRoot: "/tmp/pb", text: "b") else { Issue.record("B 应打开"); return }
        // B 保持打开;打开 C 时只能回收空闲的 A
        guard case .ready(let c) = await manager.open(path: "/tmp/pc/c.swift", projectRoot: "/tmp/pc", text: "c") else { Issue.record("C 应打开"); return }
        #expect(await manager.runningCount == 2)
        #expect(await b.client.state == .ready)
        #expect(await c.client.state == .ready)
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

/// stop 与排队写入的竞态回归:关闭后反复 send 不得因已关闭句柄的 ObjC 异常崩溃。
@Test("真实子进程:stop 之后连续 send 不崩溃")
func stdioTransportSendAfterStopDoesNotCrash() async throws {
    for _ in 0..<50 {
        let transport = LSPStdioTransport(launch: ProcessLaunch(executable: "/bin/cat"))
        _ = try transport.start()
        for _ in 0..<20 { transport.send(Data("{}".utf8)) }
        transport.stop()
        for _ in 0..<20 { transport.send(Data("{}".utf8)) }
    }
    try await Task.sleep(for: .milliseconds(200))
}


@Suite("LSP 扩展能力")
struct LSPFeatureTests {
    @Test("引用、符号、重命名、格式化、签名帮助的请求与解码")
    func requests() async throws {
        let (client, _) = try await makeScripted()
        try await client.start()
        let refs = try await client.references(uri: "file:///a.swift", at: LSPPosition(line: 1, character: 3))
        #expect(refs.count == 2 && refs[1].uri == "file:///b.swift" && refs[1].range.start.line == 7)

        let symbols = try await client.documentSymbols(uri: "file:///a.swift")
        #expect(symbols.count == 1 && symbols[0].name == "Foo" && symbols[0].kind == .struct)
        #expect(symbols[0].line == 0 && symbols[0].endLine == 9)
        #expect(symbols[0].flattened().map(\.depth) == [0, 1])
        #expect(symbols[0].children[0].kind == .method && symbols[0].children[0].line == 2)

        let edit = try await client.rename(uri: "file:///a.swift", at: LSPPosition(line: 0, character: 5), newName: "bar")
        #expect(edit.editCount == 1)
        let applied = LSPTextEdits.apply(try #require(edit.changes["file:///a.swift"]), to: "let foo = 1\n")
        #expect(applied == "let bar = 1\n")

        let format = try await client.formatting(uri: "file:///a.swift", tabSize: 2, insertSpaces: true)
        #expect(LSPTextEdits.apply(format, to: "\t\tx\n") == "  x\n")

        let help = try #require(try await client.signatureHelp(uri: "file:///a.swift", at: LSPPosition(line: 0, character: 2)))
        #expect(help.label == "f(a: Int, b: String)")
        #expect(help.activeParameter == NSRange(location: 10, length: 9))
    }

    @Test("未就绪时抛 notReady;服务器不支持的方法抛错")
    func notReadyAndUnsupported() async throws {
        let (client, _) = try await makeScripted()
        await #expect(throws: LSPError.notReady) { _ = try await client.references(uri: "file:///a", at: LSPPosition(line: 0, character: 0)) }
    }

    @Test("文本编辑应用:多处、重叠忽略、UTF-16 列与越界钳制")
    func applyEdits() {
        func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> LSPTextEdit {
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: l1, character: c1), end: LSPPosition(line: l2, character: c2)), newText: text)
        }
        #expect(LSPTextEdits.apply([edit(0, 0, 0, 1, "A"), edit(1, 0, 1, 1, "B")], to: "a\nb\n") == "A\nB\n")
        // 重叠:先出现(起点靠前、同起点更长)的保留,与之重叠的被丢弃
        #expect(LSPTextEdits.apply([edit(0, 0, 0, 3, "X"), edit(0, 1, 0, 2, "Y")], to: "abc") == "X")
        // emoji 占两个 UTF-16 单元
        #expect(LSPTextEdits.apply([edit(0, 2, 0, 3, "!")], to: "😀a") == "😀!")
        #expect(LSPTextEdits.apply([edit(5, 0, 5, 0, "end")], to: "a\n") == "a\nend")
        #expect(LSPTextEdits.apply([], to: "same") == "same")
    }

    @Test("documentChanges 形式的工作区编辑与 SymbolInformation 都能解码")
    func decodeVariants() throws {
        let value: JSONValue = ["documentChanges": [["textDocument": ["uri": "file:///x", "version": 1],
                                                    "edits": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]], "newText": "Z"]]]]]
        #expect(LSPDecode.workspaceEdit(value).changes["file:///x"]?.count == 1)
        let info: JSONValue = [["name": "g", "kind": 12, "location": ["uri": "file:///x", "range": ["start": ["line": 4, "character": 0], "end": ["line": 6, "character": 1]]]]]
        let symbols = LSPDecode.symbols(info)
        #expect(symbols.count == 1 && symbols[0].line == 4 && symbols[0].endLine == 6 && symbols[0].kind == .function)
    }
}
