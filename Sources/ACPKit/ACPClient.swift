// @author ygw
// 类型化 ACP 客户端:封装握手、会话、提示轮次与反向请求路由。

import Foundation

// MARK: - 能力与初始化

/// Agent 能力(从 `initialize` 响应解析)。
public struct AgentCapabilities: Sendable, Hashable {
    public var loadSession = false
    public var imagePrompts = false
    public var audioPrompts = false
    public var embeddedContext = false
    public var mcpHTTP = false
    public var mcpSSE = false
    public var canResume = false
    public var canClose = false
    public var canDelete = false
    public var canFork = false
    public var canList = false
    public var additionalDirectories = false
    public var canLogout = false
    /// 适配器是否支持 `_session/steering`(`_meta.steering.supported`)
    public var canSteer = false

    public init() {}

    init(json: JSONValue) {
        loadSession = json["loadSession"]?.boolValue ?? false
        imagePrompts = json["promptCapabilities"]?["image"]?.boolValue ?? false
        audioPrompts = json["promptCapabilities"]?["audio"]?.boolValue ?? false
        embeddedContext = json["promptCapabilities"]?["embeddedContext"]?.boolValue ?? false
        mcpHTTP = json["mcpCapabilities"]?["http"]?.boolValue ?? false
        mcpSSE = json["mcpCapabilities"]?["sse"]?.boolValue ?? false
        let session = json["sessionCapabilities"]
        canResume = session?["resume"] != nil
        canClose = session?["close"] != nil
        canDelete = session?["delete"] != nil
        canFork = session?["fork"] != nil
        canList = session?["list"] != nil
        additionalDirectories = session?["additionalDirectories"] != nil
        canLogout = json["auth"]?["logout"] != nil
    }
}

/// 认证方式。
public struct AuthMethod: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
}

/// 初始化结果。
public struct InitializeResult: Sendable {
    public var protocolVersion: Int
    public var capabilities: AgentCapabilities
    public var agentName: String
    public var agentTitle: String?
    public var agentVersion: String?
    public var authMethods: [AuthMethod]
    public var raw: JSONValue
}

/// 新建/恢复会话的结果。
public struct SessionSetup: Sendable {
    public var sessionId: String
    public var configOptions: [SessionConfigOption]
    public var currentModeId: String?
    public var raw: JSONValue
}

// MARK: - 事件

/// 客户端向 UI 层投递的事件。
public enum ClientEvent: Sendable {
    case sessionUpdate(sessionId: String, update: SessionUpdate)
    /// 适配器自定义的鉴权状态通知(`_auth/status_update`)
    case authStatus(kind: String, label: String?, detail: String?)
    case stderr(String)
    case malformed(String)
    case notification(method: String, params: JSONValue?)
    case closed(exitCode: Int32?)
}

// MARK: - 委托

/// 终端输出快照。
public struct TerminalOutputSnapshot: Sendable {
    public var output: String
    public var truncated: Bool
    public var exitCode: Int?
    public var signal: String?

    public init(output: String, truncated: Bool = false, exitCode: Int? = nil, signal: String? = nil) {
        self.output = output
        self.truncated = truncated
        self.exitCode = exitCode
        self.signal = signal
    }
}

/// 客户端委托:实现 Agent 反向调用的能力。
public protocol ACPClientDelegate: Sendable {
    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome
    func readTextFile(sessionId: String, path: String, line: Int?, limit: Int?) async throws -> String
    func writeTextFile(sessionId: String, path: String, content: String) async throws
    func createTerminal(sessionId: String, command: String, args: [String], env: [String: String], cwd: String?, outputByteLimit: Int?) async throws -> String
    func terminalOutput(terminalId: String) async throws -> TerminalOutputSnapshot
    func waitForTerminalExit(terminalId: String) async throws -> TerminalOutputSnapshot
    func killTerminal(terminalId: String) async throws
    func releaseTerminal(terminalId: String) async throws
    /// 结构化信息征询(elicitation)。默认取消。
    func elicit(method: String, params: JSONValue?) async throws -> JSONValue
}

public extension ACPClientDelegate {
    func readTextFile(sessionId: String, path: String, line: Int?, limit: Int?) async throws -> String {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 fs/read_text_file")
    }
    func writeTextFile(sessionId: String, path: String, content: String) async throws {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 fs/write_text_file")
    }
    func createTerminal(sessionId: String, command: String, args: [String], env: [String: String], cwd: String?, outputByteLimit: Int?) async throws -> String {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 terminal/create")
    }
    func terminalOutput(terminalId: String) async throws -> TerminalOutputSnapshot {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 terminal/output")
    }
    func waitForTerminalExit(terminalId: String) async throws -> TerminalOutputSnapshot {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 terminal/wait_for_exit")
    }
    func killTerminal(terminalId: String) async throws {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 terminal/kill")
    }
    func releaseTerminal(terminalId: String) async throws {
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现 terminal/release")
    }
    func elicit(method: String, params: JSONValue?) async throws -> JSONValue {
        ["action": "cancel"]
    }
}

/// 把协议方法路由到委托。
struct ClientRequestRouter: ACPRequestHandler {
    let delegate: any ACPClientDelegate

    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let p = params ?? .null
        let sessionId = p["sessionId"]?.stringValue ?? ""
        switch method {
        case "session/request_permission":
            return await delegate.requestPermission(PermissionRequest(json: p)).json
        case "fs/read_text_file":
            let content = try await delegate.readTextFile(sessionId: sessionId, path: p["path"]?.stringValue ?? "", line: p["line"]?.intValue, limit: p["limit"]?.intValue)
            return ["content": .string(content)]
        case "fs/write_text_file":
            try await delegate.writeTextFile(sessionId: sessionId, path: p["path"]?.stringValue ?? "", content: p["content"]?.stringValue ?? "")
            return .object([:])
        case "terminal/create":
            var env: [String: String] = [:]
            for item in p["env"]?.arrayValue ?? [] {
                if let name = item["name"]?.stringValue { env[name] = item["value"]?.stringValue ?? "" }
            }
            let id = try await delegate.createTerminal(
                sessionId: sessionId,
                command: p["command"]?.stringValue ?? "",
                args: (p["args"]?.arrayValue ?? []).compactMap(\.stringValue),
                env: env,
                cwd: p["cwd"]?.stringValue,
                outputByteLimit: p["outputByteLimit"]?.intValue
            )
            return ["terminalId": .string(id)]
        case "terminal/output":
            let snap = try await delegate.terminalOutput(terminalId: p["terminalId"]?.stringValue ?? "")
            var object: [String: JSONValue] = ["output": .string(snap.output), "truncated": .bool(snap.truncated)]
            if snap.exitCode != nil || snap.signal != nil { object["exitStatus"] = Self.exitStatus(snap) }
            return .object(object)
        case "terminal/wait_for_exit":
            let snap = try await delegate.waitForTerminalExit(terminalId: p["terminalId"]?.stringValue ?? "")
            return Self.exitStatus(snap)
        case "terminal/kill":
            try await delegate.killTerminal(terminalId: p["terminalId"]?.stringValue ?? "")
            return .object([:])
        case "terminal/release":
            try await delegate.releaseTerminal(terminalId: p["terminalId"]?.stringValue ?? "")
            return .object([:])
        default:
            if method.hasPrefix("elicitation") || method.contains("/elicit") {
                return try await delegate.elicit(method: method, params: params)
            }
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现: \(method)")
        }
    }

    private static func exitStatus(_ snap: TerminalOutputSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [:]
        object["exitCode"] = snap.exitCode.map { .int($0) } ?? .null
        object["signal"] = snap.signal.map { .string($0) } ?? .null
        return .object(object)
    }
}

// MARK: - 客户端

/// 类型化 ACP 客户端。
public actor ACPClient {
    public let connection: ACPConnection
    /// 事件流(通知、stderr、关闭)。
    public nonisolated let events: AsyncStream<ClientEvent>
    private let eventContinuation: AsyncStream<ClientEvent>.Continuation
    private var pump: Task<Void, Never>?

    public private(set) var capabilities = AgentCapabilities()

    /// 创建客户端。
    /// - Parameters:
    ///   - transport: 传输
    ///   - delegate: 反向请求委托
    public init(transport: any ACPTransport, delegate: any ACPClientDelegate) {
        let connection = ACPConnection(transport: transport)
        self.connection = connection
        let (stream, continuation) = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventContinuation = continuation
        let router = ClientRequestRouter(delegate: delegate)
        Task { await connection.setRequestHandler(router) }
    }

    /// 启动连接并开始转发事件。
    public func start() async throws {
        try await connection.start()
        let inbound = connection.inbound
        let continuation = eventContinuation
        pump = Task {
            for await item in inbound {
                switch item {
                case .notification(let method, let params):
                    if method == "session/update", let params,
                       let sessionId = params["sessionId"]?.stringValue, let update = params["update"] {
                        continuation.yield(.sessionUpdate(sessionId: sessionId, update: SessionUpdate(json: update)))
                    } else if method == "_auth/status_update", let status = params?["authStatus"] {
                        continuation.yield(.authStatus(kind: status["kind"]?.stringValue ?? "", label: status["label"]?.stringValue, detail: status["detail"]?.stringValue))
                    } else {
                        continuation.yield(.notification(method: method, params: params))
                    }
                case .stderr(let text): continuation.yield(.stderr(text))
                case .malformed(let line): continuation.yield(.malformed(line))
                case .closed(let code):
                    continuation.yield(.closed(exitCode: code))
                    continuation.finish()
                }
            }
        }
    }

    /// 关闭连接。
    public func close() async {
        await connection.close()
    }

    // MARK: 握手

    /// 发送 `initialize`。
    /// - Parameters:
    ///   - clientName: 客户端名称
    ///   - clientVersion: 版本
    ///   - fileSystem: 是否声明读写文件能力
    ///   - terminal: 是否声明终端能力
    ///   - extraCapabilities: 额外能力字段
    public func initialize(clientName: String = "OhMyAgent", clientVersion: String = "0.1.0", fileSystem: Bool = true, terminal: Bool = true, extraCapabilities: [String: JSONValue] = [:]) async throws -> InitializeResult {
        var caps: [String: JSONValue] = extraCapabilities
        caps["fs"] = ["readTextFile": .bool(fileSystem), "writeTextFile": .bool(fileSystem)]
        caps["terminal"] = .bool(terminal)
        let result = try await connection.request("initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": .object(caps),
            "clientInfo": ["name": .string(clientName), "title": .string(clientName), "version": .string(clientVersion)],
        ])
        var agentCaps = AgentCapabilities(json: result["agentCapabilities"] ?? .null)
        agentCaps.canSteer = result["_meta"]?["steering"]?["supported"]?.boolValue ?? false
        capabilities = agentCaps
        let methods = (result["authMethods"]?.arrayValue ?? []).map {
            AuthMethod(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "", description: $0["description"]?.stringValue)
        }
        return InitializeResult(
            protocolVersion: result["protocolVersion"]?.intValue ?? 1,
            capabilities: agentCaps,
            agentName: result["agentInfo"]?["name"]?.stringValue ?? "",
            agentTitle: result["agentInfo"]?["title"]?.stringValue,
            agentVersion: result["agentInfo"]?["version"]?.stringValue,
            authMethods: methods,
            raw: result
        )
    }

    /// 发送 `authenticate`。
    public func authenticate(methodId: String) async throws {
        _ = try await connection.request("authenticate", params: ["methodId": .string(methodId)])
    }

    /// 发送 `logout`(需 `auth.logout` 能力)。
    public func logout() async throws {
        _ = try await connection.request("logout", params: .object([:]))
    }

    // MARK: 会话

    private func sessionParams(cwd: String, mcpServers: [MCPServerConfig], additionalDirectories: [String], meta: JSONValue? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "mcpServers": .array(mcpServers.map(\.json))]
        if let meta { params["_meta"] = meta }
        if capabilities.additionalDirectories, !additionalDirectories.isEmpty {
            params["additionalDirectories"] = .array(additionalDirectories.map(JSONValue.string))
        }
        return params
    }

    private func parseSetup(_ result: JSONValue, fallbackId: String? = nil) -> SessionSetup {
        SessionSetup(
            sessionId: result["sessionId"]?.stringValue ?? fallbackId ?? "",
            configOptions: (result["configOptions"]?.arrayValue ?? []).map(SessionConfigOption.init(json:)),
            currentModeId: result["modes"]?["currentModeId"]?.stringValue,
            raw: result
        )
    }

    /// 创建会话。
    /// - Parameter meta: 会话级 `_meta`(如 claude-agent-acp 的 `claudeCode.options`,用于按会话指定模型提供商)
    public func newSession(cwd: String, mcpServers: [MCPServerConfig] = [], additionalDirectories: [String] = [], meta: JSONValue? = nil) async throws -> SessionSetup {
        let result = try await connection.request("session/new", params: .object(sessionParams(cwd: cwd, mcpServers: mcpServers, additionalDirectories: additionalDirectories, meta: meta)))
        return parseSetup(result)
    }

    /// 加载会话(Agent 会回放历史)。
    public func loadSession(sessionId: String, cwd: String, mcpServers: [MCPServerConfig] = [], additionalDirectories: [String] = [], meta: JSONValue? = nil) async throws -> SessionSetup {
        var params = sessionParams(cwd: cwd, mcpServers: mcpServers, additionalDirectories: additionalDirectories, meta: meta)
        params["sessionId"] = .string(sessionId)
        let result = try await connection.request("session/load", params: .object(params))
        return parseSetup(result, fallbackId: sessionId)
    }

    /// 恢复会话(不回放历史)。
    public func resumeSession(sessionId: String, cwd: String, mcpServers: [MCPServerConfig] = [], additionalDirectories: [String] = [], meta: JSONValue? = nil) async throws -> SessionSetup {
        var params = sessionParams(cwd: cwd, mcpServers: mcpServers, additionalDirectories: additionalDirectories, meta: meta)
        params["sessionId"] = .string(sessionId)
        let result = try await connection.request("session/resume", params: .object(params))
        return parseSetup(result, fallbackId: sessionId)
    }

    /// 分叉会话。
    public func forkSession(sessionId: String, cwd: String, mcpServers: [MCPServerConfig] = [], meta: JSONValue? = nil) async throws -> SessionSetup {
        var params = sessionParams(cwd: cwd, mcpServers: mcpServers, additionalDirectories: [], meta: meta)
        params["sessionId"] = .string(sessionId)
        let result = try await connection.request("session/fork", params: .object(params))
        return parseSetup(result)
    }

    /// 列出历史会话。
    /// - Parameters:
    ///   - cwd: 仅列出该目录的会话,nil 为全部
    ///   - cursor: 分页游标
    public func listSessions(cwd: String? = nil, cursor: String? = nil) async throws -> (sessions: [SessionSummary], nextCursor: String?) {
        var params: [String: JSONValue] = [:]
        if let cwd { params["cwd"] = .string(cwd) }
        if let cursor { params["cursor"] = .string(cursor) }
        let result = try await connection.request("session/list", params: .object(params))
        let sessions = (result["sessions"]?.arrayValue ?? []).map {
            SessionSummary(sessionId: $0["sessionId"]?.stringValue ?? "", cwd: $0["cwd"]?.stringValue ?? "", title: $0["title"]?.stringValue, updatedAt: $0["updatedAt"]?.stringValue)
        }
        return (sessions, result["nextCursor"]?.stringValue)
    }

    /// 关闭会话。
    public func closeSession(sessionId: String) async throws {
        _ = try await connection.request("session/close", params: ["sessionId": .string(sessionId)])
    }

    /// 删除会话。
    public func deleteSession(sessionId: String) async throws {
        _ = try await connection.request("session/delete", params: ["sessionId": .string(sessionId)])
    }

    // MARK: 提示轮次

    /// 发送提示并等待本轮结束。过程中的更新通过 `events` 到达。
    /// - Parameters:
    ///   - sessionId: 会话 id
    ///   - content: 内容块
    /// - Returns: 停止原因
    public func prompt(sessionId: String, content: [ContentBlock]) async throws -> StopReason {
        let result = try await connection.request("session/prompt", params: [
            "sessionId": .string(sessionId),
            "prompt": .array(content.map(\.json)),
        ])
        return StopReason(rawValue: result["stopReason"]?.stringValue ?? "") ?? .other
    }

    /// 引导(steering):把追加消息注入正在运行的轮次(`_session/steering`)。
    /// 没有运行中的轮次时返回 `promptRequired`,调用方应改走普通 `session/prompt`。
    /// - Parameters:
    ///   - sessionId: 会话 id
    ///   - content: 内容块
    /// - Returns: 适配器的结果:`injected` / `promptRequired` / `startedNewTurn`
    public func steer(sessionId: String, content: [ContentBlock]) async throws -> String {
        let result = try await connection.request("_session/steering", params: [
            "sessionId": .string(sessionId),
            "prompt": .array(content.map(\.json)),
            "_meta": ["steering": ["idleBehavior": "promptRequired"]],
        ])
        return result["outcome"]?.stringValue ?? "injected"
    }

    /// 发送任意扩展请求(以 `_` 开头的自定义方法)。
    /// - Parameters:
    ///   - method: 方法名
    ///   - params: 参数
    /// - Returns: 响应结果
    public func extensionRequest(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await connection.request(method, params: params)
    }

    /// 取消当前轮次。
    public func cancel(sessionId: String) async {
        await connection.notify("session/cancel", params: ["sessionId": .string(sessionId)])
    }

    /// 切换模式。
    public func setMode(sessionId: String, modeId: String) async throws {
        _ = try await connection.request("session/set_mode", params: ["sessionId": .string(sessionId), "modeId": .string(modeId)])
    }

    /// 设置配置选项(模型、思考强度等)。
    /// - Returns: 更新后的完整配置选项
    public func setConfigOption(sessionId: String, configId: String, value: JSONValue) async throws -> [SessionConfigOption] {
        let result = try await connection.request("session/set_config_option", params: [
            "sessionId": .string(sessionId), "configId": .string(configId), "value": value,
        ])
        return (result["configOptions"]?.arrayValue ?? []).map(SessionConfigOption.init(json:))
    }
}
