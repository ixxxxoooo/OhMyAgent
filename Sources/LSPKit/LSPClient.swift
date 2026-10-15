// @author ygw
// LSP 客户端 actor:初始化握手、文档同步、诊断订阅与 hover/定义/补全请求。
// JSON-RPC 往返复用 ACPKit 的 `ACPConnection`(传输层负责 Content-Length 分帧)。

import ACPKit
import Foundation
import OMLog

/// LSP 客户端错误。
public enum LSPError: Error, Sendable, Equatable, LocalizedError {
    case notReady
    case timeout(method: String)
    case initializeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "语言服务器尚未就绪"
        case .timeout(let method): return "语言服务器请求超时:\(method)"
        case .initializeFailed(let message): return "语言服务器初始化失败:\(message)"
        }
    }
}

/// 处理服务器发给客户端的请求。多数只需礼貌地确认,避免服务器等待。
struct LSPRequestHandler: ACPRequestHandler {
    let rootURI: String
    let rootName: String

    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "workspace/configuration":
            // 每个配置项都答 null,让服务器使用默认值
            let count = params?["items"]?.arrayValue?.count ?? 0
            return .array(Array(repeating: .null, count: count))
        case "workspace/workspaceFolders":
            return .array([["uri": .string(rootURI), "name": .string(rootName)]])
        case "client/registerCapability", "client/unregisterCapability",
             "window/workDoneProgress/create", "window/showMessageRequest", "window/showDocument":
            return .null
        case "workspace/applyEdit":
            return ["applied": false]
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现: \(method)")
        }
    }
}

/// 一个语言服务器的客户端。
public actor LSPClient {
    /// 日志与界面用的名称(如 `swift`)
    public nonisolated let label: String
    /// 工作区根目录
    public nonisolated let rootPath: String

    private let connection: ACPConnection
    private let log: OMLogger
    public private(set) var state: LSPClientState = .idle
    /// 服务器在 initialize 响应里声明的能力
    public private(set) var capabilities: JSONValue = .null
    /// 服务器名称(来自 `serverInfo`)
    public private(set) var serverName: String?

    private var documents: [String: Int] = [:]
    private var latest: [String: LSPDiagnosticsUpdate] = [:]
    private var subscribers: [UUID: AsyncStream<LSPDiagnosticsUpdate>.Continuation] = [:]
    private var inboundTask: Task<Void, Never>?
    private var closedHandler: (@Sendable () -> Void)?
    private let requestTimeout: Duration

    /// 创建客户端(尚未启动)。
    /// - Parameters:
    ///   - transport: 传输(子进程 stdio 或测试替身)
    ///   - rootPath: 工作区根目录(绝对路径)
    ///   - label: 名称
    ///   - requestTimeout: hover/定义/补全的请求超时
    public init(transport: any ACPTransport, rootPath: String, label: String, requestTimeout: Duration = .seconds(8)) {
        self.requestTimeout = requestTimeout
        self.label = label
        self.rootPath = rootPath
        self.connection = ACPConnection(transport: transport, label: "lsp:\(label)")
        self.log = Log.lsp.with(["server": label])
    }

    /// 服务器进程退出或连接关闭时回调(只触发一次)。
    public func setClosedHandler(_ handler: @escaping @Sendable () -> Void) {
        closedHandler = handler
    }

    /// 当前已打开的文档数。
    public var openDocumentCount: Int { documents.count }

    /// 是否已打开某文档。
    public func isOpen(_ uri: String) -> Bool { documents[uri] != nil }

    // MARK: - 生命周期

    /// 启动连接并完成 initialize / initialized 握手。
    /// - Parameter timeout: 握手超时,冷启动索引较慢的服务器需要放宽
    /// - Throws: 启动失败、握手超时或服务器返回错误
    public func start(timeout: Duration = .seconds(60)) async throws {
        guard state == .idle else { return }
        state = .starting
        let begin = ContinuousClock.now
        let rootURI = LSPURI.make(path: rootPath)
        let name = (rootPath as NSString).lastPathComponent
        await connection.setRequestHandler(LSPRequestHandler(rootURI: rootURI, rootName: name))
        do {
            try await connection.start()
        } catch {
            state = .failed(error.localizedDescription)
            log.error("语言服务器连接启动失败", error: error)
            throw error
        }
        let inbound = connection.inbound
        inboundTask = Task { [weak self] in
            for await event in inbound { await self?.handle(event) }
        }
        do {
            let result = try await send("initialize", Self.initializeParams(rootURI: rootURI, rootName: name), timeout: timeout)
            capabilities = result["capabilities"] ?? .null
            serverName = result["serverInfo"]?["name"]?.stringValue
            await connection.notify("initialized", params: [:])
            state = .ready
            let elapsed = begin.duration(to: ContinuousClock.now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            log.info("语言服务器就绪", ["root": rootPath, "serverName": serverName ?? "-", "ms": "\(ms)"])
        } catch {
            state = .failed(error.localizedDescription)
            log.error("语言服务器初始化失败", error: error, ["root": rootPath])
            await connection.close()
            throw LSPError.initializeFailed(error.localizedDescription)
        }
    }

    /// 礼貌关闭:shutdown → exit → 结束进程。
    public func shutdown() async {
        guard state == .ready || state == .starting else {
            await connection.close()
            return
        }
        state = .closed
        _ = try? await send("shutdown", nil, timeout: .seconds(2))
        await connection.notify("exit")
        await connection.close()
        finishSubscribers()
        documents.removeAll()
        log.info("语言服务器已关闭")
    }

    /// initialize 请求参数。
    static func initializeParams(rootURI: String, rootName: String) -> JSONValue {
        [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "OhMyAgent"],
            "rootUri": .string(rootURI),
            "workspaceFolders": .array([["uri": .string(rootURI), "name": .string(rootName)]]),
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "workspace": ["workspaceFolders": true, "configuration": true],
                "textDocument": [
                    "synchronization": ["didSave": true, "dynamicRegistration": false],
                    "publishDiagnostics": ["versionSupport": true],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "definition": ["linkSupport": true],
                    "completion": ["completionItem": ["snippetSupport": false]],
                ],
            ],
        ]
    }

    // MARK: - 文档同步

    /// 打开文档。已打开则当作整篇更新。
    /// - Returns: 当前文档版本
    @discardableResult
    public func didOpen(uri: String, languageID: String, text: String) async -> Int {
        if documents[uri] != nil { return await didChange(uri: uri, text: text) }
        let version = 1
        documents[uri] = version
        await connection.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(uri), "languageId": .string(languageID), "version": .int(version), "text": .string(text)],
        ])
        return version
    }

    /// 整篇文本变更(无 range 的内容变更对任意同步模式都合法)。
    /// - Returns: 变更后的文档版本;文档未打开返回 0
    @discardableResult
    public func didChange(uri: String, text: String) async -> Int {
        guard let current = documents[uri] else { return 0 }
        let version = current + 1
        documents[uri] = version
        await connection.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(uri), "version": .int(version)],
            "contentChanges": [["text": .string(text)]],
        ])
        return version
    }

    /// 通知文档已保存。
    public func didSave(uri: String, text: String) async {
        guard documents[uri] != nil else { return }
        await connection.notify("textDocument/didSave", params: [
            "textDocument": ["uri": .string(uri)], "text": .string(text),
        ])
    }

    /// 关闭文档。
    public func didClose(uri: String) async {
        guard documents.removeValue(forKey: uri) != nil else { return }
        latest[uri] = nil
        await connection.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(uri)]])
    }

    // MARK: - 诊断

    /// 订阅诊断更新(每次调用得到独立的流;当前缓存会先行投递)。
    public func diagnosticUpdates() -> AsyncStream<LSPDiagnosticsUpdate> {
        let (stream, continuation) = AsyncStream<LSPDiagnosticsUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        for update in latest.values { continuation.yield(update) }
        return stream
    }

    /// 某文档最近一次诊断。
    public func diagnostics(for uri: String) -> [LSPDiagnostic] { latest[uri]?.diagnostics ?? [] }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func finishSubscribers() {
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: - 查询

    /// 悬停信息。
    /// - Returns: 纯文本/Markdown 文本;无信息为 nil
    public func hover(uri: String, at position: LSPPosition) async throws -> String? {
        let result = try await query("textDocument/hover", uri: uri, position: position, timeout: requestTimeout)
        return LSPDecode.hoverText(result)
    }

    /// 跳转定义。
    public func definition(uri: String, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPDecode.locations(try await query("textDocument/definition", uri: uri, position: position, timeout: requestTimeout))
    }

    /// 补全候选。
    public func completion(uri: String, at position: LSPPosition) async throws -> [LSPCompletionItem] {
        LSPDecode.completions(try await query("textDocument/completion", uri: uri, position: position, timeout: requestTimeout))
    }

    private func query(_ method: String, uri: String, position: LSPPosition, timeout: Duration) async throws -> JSONValue {
        guard state == .ready else { throw LSPError.notReady }
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "position": ["line": .int(position.line), "character": .int(position.character)],
        ]
        return try await send(method, params, timeout: timeout)
    }

    /// 带超时的请求:超时后取消底层请求(会向服务器发取消通知)。
    private func send(_ method: String, _ params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        let connection = self.connection
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await connection.request(method, params: params) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LSPError.timeout(method: method)
            }
            guard let first = try await group.next() else { throw LSPError.timeout(method: method) }
            group.cancelAll()
            return first
        }
    }

    // MARK: - 入站

    private func handle(_ event: ACPInbound) {
        switch event {
        case .notification(let method, let params):
            switch method {
            case "textDocument/publishDiagnostics": publish(params)
            case "window/logMessage", "window/showMessage":
                log.debug("服务器消息", ["text": String((params?["message"]?.stringValue ?? "").prefix(300))])
            default: break
            }
        case .stderr(let text):
            log.debug("服务器 stderr", ["text": String(text.prefix(300))])
        case .malformed:
            break
        case .closed(let code):
            if state != .closed { state = .closed }
            log.info("语言服务器连接关闭", ["exit": code.map { "\($0)" } ?? "-"])
            finishSubscribers()
            closedHandler?()
            closedHandler = nil
        }
    }

    private func publish(_ params: JSONValue?) {
        guard let params, let uri = params["uri"]?.stringValue else { return }
        let items = params["diagnostics"]?.arrayValue ?? []
        let diagnostics = items.compactMap { try? $0.decode(LSPDiagnostic.self) }
        let update = LSPDiagnosticsUpdate(uri: uri, version: params["version"]?.intValue, diagnostics: diagnostics)
        latest[uri] = update
        for (_, continuation) in subscribers { continuation.yield(update) }
    }
}

/// 文件路径与 `file://` URI 互转。
public enum LSPURI {
    /// - Parameter path: 绝对路径
    /// - Returns: `file:///...` URI(已百分号编码)
    public static func make(path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    /// - Parameter uri: `file://` URI
    /// - Returns: 本地路径;不是 file URI 返回 nil
    public static func path(from uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
