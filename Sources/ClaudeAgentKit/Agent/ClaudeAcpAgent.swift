// @author ixxxxoooo
// 原生 Swift 版 Claude ACP 适配器:对客户端是一个 ACP v1 Agent,对 `claude` 是一组 stream-json 会话。
// 取代 Node 的 `@agentclientprotocol/claude-agent-acp`,以进程内 actor 形式运行(经内存传输接入 `ACPConnection`)。

import ACPKit
import Foundation
import OMLog

/// 原生 Claude ACP Agent。
public actor ClaudeAcpAgent: ACPRequestHandler {
    private struct Live {
        var session: ClaudeSession
        var fingerprint: String
        var ended = false
    }

    private let connection: ACPConnection
    private let link: ConnectionClientLink
    private let config: ClaudeAgentConfig
    private let log = Log.agent.with(["part": "acp-agent"])
    private var caps = ClientCaps()
    private let auth: AuthStatusCenter
    private var live: [String: Live] = [:]
    private var pump: Task<Void, Never>?
    private var closedHandler: (@Sendable () -> Void)?

    /// 页大小:`session/list` 一页的会话数。
    static let listPageSize = 1000

    /// 创建 Agent。
    /// - Parameters:
    ///   - connection: 与客户端相连的 ACP 连接(Agent 侧)
    ///   - config: 适配器配置
    public init(connection: ACPConnection, config: ClaudeAgentConfig) {
        self.connection = connection
        let link = ConnectionClientLink(connection: connection)
        self.link = link
        self.config = config
        self.auth = AuthStatusCenter(config: config, link: link)
    }

    /// 注册请求处理并启动连接;开始转发 `session/cancel` 等通知。
    /// - Parameter onClose: 连接关闭时回调
    public func start(onClose: (@Sendable () -> Void)? = nil) async throws {
        closedHandler = onClose
        await connection.setRequestHandler(self)
        try await connection.start()
        let inbound = connection.inbound
        pump = Task { [weak self] in
            for await item in inbound {
                switch item {
                case .notification(let method, let params):
                    if method == "session/cancel", let id = params?["sessionId"]?.stringValue { await self?.cancel(id) }
                case .closed:
                    await self?.connectionClosed()
                default:
                    break
                }
            }
        }
    }

    /// 关闭全部会话与连接。
    public func shutdown() async {
        pump?.cancel()
        pump = nil
        let sessions = live.values.map(\.session)
        live.removeAll()
        for session in sessions { await session.close() }
        await connection.close()
    }

    private func connectionClosed() async {
        log.info("客户端连接已关闭,清理会话", ["sessions": "\(live.count)"])
        let sessions = live.values.map(\.session)
        live.removeAll()
        for session in sessions { await session.close() }
        closedHandler?()
    }

    private func cancel(_ sessionId: String) async {
        await live[sessionId]?.session.cancel()
    }

    // MARK: 请求分发

    public func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        do {
            return try await dispatch(method: method, params: params)
        } catch let error as JSONRPCError where error.code == JSONRPCError.internalError && error.data == nil {
            // 与 Node 版一致:普通异常以 “Internal error” + data.details 返回
            throw JSONRPCError(code: JSONRPCError.internalError, message: "Internal error", data: ["details": .string(error.message)])
        }
    }

    private func dispatch(method: String, params: JSONValue?) async throws -> JSONValue {
        let p = params ?? .object([:])
        switch method {
        case "initialize": return await initialize(p)
        case "authenticate": return try await authenticate(p)
        case "logout": return try await logout()
        case "session/new": return try await newSession(p)
        case "session/load": return try await loadSession(p)
        case "session/resume": return try await resumeSession(p)
        case "session/fork": return try await forkSession(p)
        case "session/list": return listSessions(p)
        case "session/close": return await closeSession(p)
        case "session/delete": return try await deleteSession(p)
        case "session/set_mode": return try await setMode(p)
        case "session/set_config_option": return try await setConfigOption(p)
        case "session/prompt": return try await prompt(p)
        case "_session/steering": return try await steering(p)
        case "_session/rename": return try await rename(p)
        case "_session/context_usage": return try await session(p).contextUsage()
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "\"Method not found\": \(method)", data: ["method": .string(method)])
        }
    }

    // MARK: 握手与鉴权

    private func initialize(_ params: JSONValue) async -> JSONValue {
        caps = ClientCaps(raw: params["clientCapabilities"] ?? .object([:]))
        // 后台读取鉴权身份:不阻塞 initialize,结果经 `_auth/status_update` 推送
        let center = auth
        Task { await center.probeInBackground() }
        var methods: [JSONValue] = []
        if caps.terminalAuth || caps.raw.at("_meta", "terminal-auth")?.boolValue == true {
            methods.append(["id": "claude-ai-login", "name": "Claude Subscription", "description": "Use Claude subscription ", "type": "terminal",
                            "args": ["auth", "login", "--claudeai"]])
            methods.append(["id": "console-login", "name": "Anthropic Console", "description": "Use Anthropic Console (API usage billing)", "type": "terminal",
                            "args": ["auth", "login", "--console"]])
        }
        if caps.gatewayAuth {
            methods.append(["id": "gateway", "name": "Custom model gateway", "description": "Use a custom gateway to authenticate and access models", "_meta": ["gateway": ["protocol": "anthropic"]]])
            methods.append(["id": "gateway-bedrock", "name": "Custom model gateway", "description": "Use a custom gateway to authenticate and access models", "_meta": ["gateway": ["protocol": "bedrock"]]])
        }
        return [
            "protocolVersion": 1,
            "agentCapabilities": [
                "_meta": ["claudeCode": ["promptQueueing": true], "authStatus": .object([:])],
                "promptCapabilities": ["image": true, "embeddedContext": true],
                "mcpCapabilities": ["http": true, "sse": true],
                "auth": ["logout": .object([:])],
                "loadSession": true,
                "sessionCapabilities": [
                    "additionalDirectories": .object([:]), "close": .object([:]), "delete": .object([:]),
                    "fork": .object([:]), "list": .object([:]), "resume": .object([:]),
                ],
            ],
            "agentInfo": ["name": "claude-agent-acp", "title": "Claude Agent", "version": .string(config.version)],
            "authMethods": .array(methods),
            "_meta": ["steering": ["supported": true]],
        ]
    }

    private func authenticate(_ params: JSONValue) async throws -> JSONValue {
        let method = params["methodId"]?.stringValue
        if method == "gateway" || method == "gateway-bedrock" {
            let baseUrl = params.at("_meta", "gateway", "baseUrl")?.stringValue
            await auth.gatewayAuthenticated(baseUrl: baseUrl)
            return .object([:])
        }
        throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "不支持的鉴权方式:\(method ?? "-")")
    }

    private func logout() async throws -> JSONValue {
        do {
            let result = try await CLIRunner.run(executable: config.executable, arguments: ["auth", "logout"], environment: config.environment)
            guard result.status == 0 else {
                throw JSONRPCError(code: JSONRPCError.internalError, message: "claude auth logout failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch let error as JSONRPCError {
            throw error
        } catch {
            log.error("登出失败", error: error)
            throw JSONRPCError(code: JSONRPCError.internalError, message: "claude auth logout failed: \(error.localizedDescription)")
        }
        await auth.afterLogout()
        return .object([:])
    }

    // MARK: 会话创建

    private func validateCwd(_ cwd: String) throws {
        guard cwd.hasPrefix("/") else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "`cwd` must be an absolute path, but received: \(cwd)", data: ["cwd": .string(cwd)])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "`cwd` does not exist on the machine running the agent: \(cwd)", data: ["cwd": .string(cwd)])
        }
        guard isDirectory.boolValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "`cwd` is not a directory: \(cwd)", data: ["cwd": .string(cwd)])
        }
    }

    private func forwardsSubagentText(_ spec: SessionSpec) -> Bool {
        caps.subagentTranscript || spec.meta?.at("claudeCode", "options", "forwardSubagentText")?.boolValue == true
    }

    /// 创建并启动一个会话,登记到表里。
    private func createSession(id: String, spec: SessionSpec, creation: SessionCreation) async throws -> ClaudeSession {
        try validateCwd(spec.cwd)
        let session = ClaudeSession(
            id: id, spec: spec, config: config, client: link, caps: caps, forwardSubagentText: forwardsSubagentText(spec),
            onEnded: { [weak self] ended in await self?.sessionEnded(ended) }
        )
        try await session.boot(creation)
        live[id] = Live(session: session, fingerprint: spec.fingerprint)
        await auth.publish(sessionAccount: await session.account)
        await auth.probeInBackground()
        return session
    }

    private func sessionEnded(_ id: String) {
        live[id]?.ended = true
    }

    private func setupResponse(_ session: ClaudeSession, includeSessionId: Bool = true) async -> JSONValue {
        var response: [String: JSONValue] = ["modes": await session.modesJSON, "configOptions": .array(await session.configOptions)]
        if includeSessionId { response["sessionId"] = .string(session.id) }
        scheduleAfterSetup(session)
        return .object(response)
    }

    /// 响应发出后异步推送可用命令。
    private func scheduleAfterSetup(_ session: ClaudeSession) {
        Task {
            await session.sendAvailableCommands()
            await session.startMcpAuthentication()
        }
    }

    private func newSession(_ params: JSONValue) async throws -> JSONValue {
        let spec = SessionSpec(params: params)
        let resume = params.at("_meta", "claudeCode", "options", "resume")?.stringValue
        let id = resume ?? UUID().uuidString.lowercased()
        let session = try await createSession(id: id, spec: spec, creation: SessionCreation(resume: resume))
        return await setupResponse(session)
    }

    /// 取得(或重建)已有会话。同参数的存活会话直接复用;参数不同则拆掉重建并沿用当前模式。
    private func getOrCreate(_ params: JSONValue, sessionId: String, resumedModelHint: String?? = nil) async throws -> ClaudeSession {
        let spec = SessionSpec(params: params)
        var livePermissionMode: String?
        if let existing = live[sessionId] {
            if existing.fingerprint == spec.fingerprint, !existing.ended { return existing.session }
            livePermissionMode = await existing.session.currentMode
            live[sessionId] = nil
            await existing.session.close()
        }
        var creation = SessionCreation(resume: sessionId)
        creation.permissionMode = livePermissionMode
        if let resumedModelHint { creation.resumedModelHint = resumedModelHint }
        return try await createSession(id: sessionId, spec: spec, creation: creation)
    }

    private func resumeSession(_ params: JSONValue) async throws -> JSONValue {
        let id = try requireSessionId(params)
        let session = try await getOrCreate(params, sessionId: id)
        return await setupResponse(session)
    }

    private func loadSession(_ params: JSONValue) async throws -> JSONValue {
        let id = try requireSessionId(params)
        try validateCwd(SessionSpec(params: params).cwd)
        let started = ContinuousClock.now
        let store = config.store
        let cwd = SessionSpec(params: params).cwd
        let transcript = await Task.detached { store.messages(sessionId: id, cwd: cwd) }.value
        let hint: String?? = .some(TranscriptStore.resumedModel(from: transcript))
        // 先回放再拉起 `claude`:历史不依赖进程,客户端无需等进程启动(1–2 秒)就能看到内容;进程启动失败时内容仍在
        let output = await replay(transcript, sessionId: id, cwd: cwd)
        let replayedMs = OMLogger.milliseconds(since: started)
        let session = try await getOrCreate(params, sessionId: id, resumedModelHint: hint)
        await session.adoptReplay(messageIdToUuid: output.messageIdToUuid)
        log.info("会话已加载", ["session": id, "messages": "\(transcript.count)", "replayMs": "\(replayedMs)", "ms": "\(OMLogger.milliseconds(since: started))"])
        return await setupResponse(session)
    }

    /// 回放历史为 `session/update`。
    private func replay(_ messages: [JSONValue], sessionId: String, cwd: String) async -> ReplayOutput {
        guard !messages.isEmpty else { return ReplayOutput() }
        var translator = MessageTranslator(renderer: ToolCallRenderer(capabilities: ToolRenderCapabilities(clientCapabilities: caps.raw)), cwd: cwd)
        translator.supportsPlan = caps.plan
        var engine = ReplayEngine(translator: translator, forwardSubagentText: forwardsSubagentText(SessionSpec(params: ["cwd": .string(cwd)])))
        let output = engine.run(messages)
        for update in output.updates { await link.sessionUpdate(sessionId, update) }
        return output
    }

    private func forkSession(_ params: JSONValue) async throws -> JSONValue {
        let source = try requireSessionId(params)
        let spec = SessionSpec(params: params)
        let id = UUID().uuidString.lowercased()
        var creation = SessionCreation(resume: source)
        creation.fork = true
        let session = try await createSession(id: id, spec: spec, creation: creation)
        return await setupResponse(session)
    }

    // MARK: 列表与删除

    private func listSessions(_ params: JSONValue) -> JSONValue {
        let offset = Self.listOffset(params["cursor"]?.stringValue)
        let cwd = params["cwd"]?.nonEmptyString
        let found = config.store.list(cwd: cwd, limit: Self.listPageSize + 1, offset: offset)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let visible: [JSONValue] = found.prefix(Self.listPageSize).compactMap { info in
            guard let cwd = info.cwd else { return nil }
            return ["sessionId": .string(info.sessionId), "cwd": .string(cwd), "title": .string(ClaudeSession.sanitizeTitle(info.summary)), "updatedAt": .string(formatter.string(from: info.lastModified))]
        }
        var response: [String: JSONValue] = ["sessions": .array(visible)]
        if found.count > Self.listPageSize { response["nextCursor"] = .string("offset:\(offset + Self.listPageSize)") }
        return .object(response)
    }

    /// 解析 `offset:N` 游标。
    static func listOffset(_ cursor: String?) -> Int {
        guard let cursor, cursor.hasPrefix("offset:"), let value = Int(cursor.dropFirst(7)), value >= 0 else { return 0 }
        return value
    }

    private func closeSession(_ params: JSONValue) async -> JSONValue {
        if let id = params["sessionId"]?.stringValue, let entry = live.removeValue(forKey: id) { await entry.session.close() }
        return .object([:])
    }

    private func deleteSession(_ params: JSONValue) async throws -> JSONValue {
        let id = try requireSessionId(params)
        if let entry = live.removeValue(forKey: id) { await entry.session.close() }
        let store = config.store, cwd = params["cwd"]?.nonEmptyString
        do {
            try store.delete(sessionId: id, cwd: cwd)
        } catch {
            log.error("删除会话失败", error: error, ["session": id])
            throw JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription)
        }
        return .object([:])
    }

    // MARK: 会话内操作

    private func requireSessionId(_ params: JSONValue) throws -> String {
        guard let id = params["sessionId"]?.nonEmptyString, TranscriptStore.isValidSessionId(id) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少或非法的 sessionId")
        }
        return id
    }

    private func session(_ params: JSONValue) throws -> ClaudeSession {
        guard let id = params["sessionId"]?.stringValue, let entry = live[id] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Session not found")
        }
        return entry.session
    }

    private func setMode(_ params: JSONValue) async throws -> JSONValue {
        let session = try session(params)
        guard let mode = params["modeId"]?.stringValue else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 modeId") }
        _ = try await session.setMode(mode)
        return .object([:])
    }

    private func setConfigOption(_ params: JSONValue) async throws -> JSONValue {
        let session = try session(params)
        guard let configId = params["configId"]?.stringValue, let value = params["value"] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 configId 或 value")
        }
        return ["configOptions": .array(try await session.setConfigOption(configId: configId, value: value))]
    }

    private func prompt(_ params: JSONValue) async throws -> JSONValue {
        let session = try session(params)
        guard let blocks = params["prompt"]?.arrayValue else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 prompt") }
        // 每次提问开头重读一次身份(发现终端里的登录/登出),不等待
        await auth.probeInBackground()
        return try await session.prompt(blocks)
    }

    private func steering(_ params: JSONValue) async throws -> JSONValue {
        let session = try session(params)
        guard let blocks = params["prompt"]?.arrayValue else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 prompt") }
        let promptRequired = params.at("_meta", "steering", "idleBehavior")?.stringValue == "promptRequired"
        return try await session.steer(blocks, promptRequired: promptRequired)
    }

    private func rename(_ params: JSONValue) async throws -> JSONValue {
        let session = try session(params)
        try await session.renameTitle(params["title"]?.stringValue ?? "")
        return .object([:])
    }
}
