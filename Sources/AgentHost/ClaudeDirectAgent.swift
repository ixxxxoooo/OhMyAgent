// @author ygw
// 直连兜底 Agent:在 ACP 适配器不可用(缺 Node/适配器)时,用 `claude -p` 的 stream-json 输出对外表现为一个标准 ACP Agent。
// 每个提示轮次拉起一次 claude 子进程(首轮 --session-id,之后 --resume),界面与会话模型完全复用。

import ACPKit
import Foundation
import Synchronization

/// 单个直连会话的状态。
struct DirectSession {
    var cwd: String
    var claudeSessionId: String
    var started = false
    var mode = "default"
    var model = "default"
    var mcpServers: [JSONValue] = []
    var process: Process?
    var cancelled = false
}

/// 直连兜底 Agent。
public actor ClaudeDirectAgent: ACPRequestHandler {
    public let connection: ACPConnection
    private let claudePath: String
    private let environment: [String: String]
    private let onClose: (@Sendable () -> Void)?
    private var sessions: [String: DirectSession] = [:]
    private var counter = 0
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - transport: Agent 侧传输
    ///   - claudePath: `claude` 可执行文件路径
    ///   - environment: 子进程额外环境变量
    ///   - onClose: 连接关闭回调
    public init(transport: any ACPTransport, claudePath: String, environment: [String: String] = [:], onClose: (@Sendable () -> Void)? = nil) {
        self.connection = ACPConnection(transport: transport)
        self.claudePath = claudePath
        self.environment = environment
        self.onClose = onClose
    }

    /// 启动并开始处理请求。
    public func start() async throws {
        await connection.setRequestHandler(self)
        try await connection.start()
        let inbound = connection.inbound
        pump = Task { [weak self] in
            for await item in inbound {
                switch item {
                case .notification(let method, let params):
                    if method == "session/cancel", let id = params?["sessionId"]?.stringValue { await self?.cancel(id) }
                case .closed:
                    await self?.closed()
                default:
                    break
                }
            }
        }
    }

    private func closed() {
        for key in sessions.keys { sessions[key]?.process?.terminate() }
        onClose?()
    }

    private func cancel(_ id: String) {
        sessions[id]?.cancelled = true
        sessions[id]?.process?.terminate()
    }

    // MARK: - 请求

    public func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let p = params ?? .null
        switch method {
        case "initialize":
            return [
                "protocolVersion": 1,
                "agentCapabilities": [
                    "loadSession": false,
                    "promptCapabilities": ["image": false, "embeddedContext": true],
                    "mcpCapabilities": ["http": true, "sse": true],
                ],
                "agentInfo": ["name": "claude-direct", "title": "Claude Code(直连)", "version": "0.1.0"],
                "authMethods": .array([]),
            ]
        case "authenticate", "logout":
            return .object([:])
        case "session/new":
            counter += 1
            let id = "direct-\(counter)"
            var session = DirectSession(cwd: p["cwd"]?.stringValue ?? NSTemporaryDirectory(), claudeSessionId: UUID().uuidString.lowercased())
            session.mcpServers = p["mcpServers"]?.arrayValue ?? []
            sessions[id] = session
            return ["sessionId": .string(id), "configOptions": configOptions(id)]
        case "session/close":
            if let id = p["sessionId"]?.stringValue { cancel(id); sessions[id] = nil }
            return .object([:])
        case "session/set_mode":
            if let id = p["sessionId"]?.stringValue, let mode = p["modeId"]?.stringValue { sessions[id]?.mode = mode }
            return .object([:])
        case "session/set_config_option":
            guard let id = p["sessionId"]?.stringValue, let configId = p["configId"]?.stringValue, let value = p["value"]?.stringValue else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少参数")
            }
            if configId == "mode" { sessions[id]?.mode = value } else if configId == "model" { sessions[id]?.model = value }
            return ["configOptions": configOptions(id)]
        case "session/prompt":
            return try await prompt(p)
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "直连通道不支持 \(method)")
        }
    }

    private func configOptions(_ id: String) -> JSONValue {
        let session = sessions[id]
        return [
            ["id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": .string(session?.mode ?? "default"),
             "options": [["value": "default", "name": "Manual"], ["value": "acceptEdits", "name": "Accept edits"],
                         ["value": "plan", "name": "Plan"], ["value": "bypassPermissions", "name": "Bypass permissions"]]],
            ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": .string(session?.model ?? "default"),
             "options": [["value": "default", "name": "默认"], ["value": "sonnet", "name": "Sonnet"], ["value": "opus", "name": "Opus"], ["value": "haiku", "name": "Haiku"]]],
        ]
    }

    // MARK: - 提示轮次

    /// 构造 claude 命令行参数(单独抽出便于测试)。
    static func arguments(session: DirectSession) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", session.mode]
        args += session.started ? ["--resume", session.claudeSessionId] : ["--session-id", session.claudeSessionId]
        if session.model != "default" { args += ["--model", session.model] }
        if let config = mcpConfig(session.mcpServers) { args += ["--mcp-config", config] }
        return args
    }

    /// ACP 的 `mcpServers` → claude 的 `--mcp-config` JSON。
    static func mcpConfig(_ servers: [JSONValue]) -> String? {
        var result: [String: JSONValue] = [:]
        func pairs(_ value: JSONValue?) -> JSONValue {
            var dict: [String: JSONValue] = [:]
            for item in value?.arrayValue ?? [] { if let name = item["name"]?.stringValue { dict[name] = item["value"] ?? "" } }
            return .object(dict)
        }
        for server in servers {
            guard let name = server["name"]?.stringValue else { continue }
            if let type = server["type"]?.stringValue, type == "http" || type == "sse" {
                result[name] = ["type": .string(type), "url": server["url"] ?? "", "headers": pairs(server["headers"])]
            } else if let command = server["command"]?.stringValue {
                result[name] = ["type": "stdio", "command": .string(command), "args": server["args"] ?? .array([]), "env": pairs(server["env"])]
            }
        }
        guard !result.isEmpty else { return nil }
        return JSONValue.object(["mcpServers": .object(result)]).compactDescription
    }

    /// 把 prompt 内容块拼成纯文本(resource_link → @路径,内嵌资源 → 文本)。
    static func promptText(_ blocks: [JSONValue]) -> String {
        blocks.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue
            case "resource_link": return block["uri"]?.stringValue.map { "@" + ($0.hasPrefix("file://") ? String($0.dropFirst(7)) : $0) }
            case "resource": return block["resource"]?["text"]?.stringValue
            default: return nil
            }
        }.joined(separator: "\n")
    }

    private func update(_ sessionId: String, _ update: JSONValue) async {
        await connection.notify("session/update", params: ["sessionId": .string(sessionId), "update": update])
    }

    private func prompt(_ p: JSONValue) async throws -> JSONValue {
        guard let id = p["sessionId"]?.stringValue, var session = sessions[id] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "未知会话")
        }
        session.cancelled = false
        let text = Self.promptText(p["prompt"]?.arrayValue ?? [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = Self.arguments(session: session)
        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let (lines, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let framer = Mutex(LineFramer())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; continuation.finish(); return }
            for line in framer.withLock({ $0.push(chunk) }) { continuation.yield(line) }
        }
        let errorTail = Mutex(Data())
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            errorTail.withLock { $0.append(chunk); if $0.count > 4096 { $0 = $0.suffix(4096) } }
        }
        do { try process.run() } catch {
            return try await fail(id, "无法启动 claude:\(error.localizedDescription)")
        }
        session.process = process
        sessions[id] = session
        stdin.fileHandleForWriting.write(Data(text.utf8))
        try? stdin.fileHandleForWriting.close()

        var translator = ClaudeStreamTranslator()
        var result: DirectResult?
        for await line in lines {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            for output in translator.translate(event) {
                switch output {
                case .update(let value): await update(id, value)
                case .sessionId(let claudeId): sessions[id]?.claudeSessionId = claudeId; sessions[id]?.started = true
                case .finished(let finished): result = finished
                }
            }
        }
        await Task.detached { process.waitUntilExit() }.value
        sessions[id]?.process = nil
        if sessions[id]?.cancelled == true { return ["stopReason": "cancelled"] }
        guard let result else {
            let tail = String(decoding: errorTail.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return try await fail(id, tail.isEmpty ? "claude 异常退出(退出码 \(process.terminationStatus))" : tail)
        }
        return await finish(id, result)
    }

    private func fail(_ id: String, _ message: String) async throws -> JSONValue {
        await update(id, ClaudeStreamTranslator.chunk("agent_message_chunk", "⚠️ \(message)", nil))
        return ["stopReason": "end_turn"]
    }

    private func finish(_ id: String, _ result: DirectResult) async -> JSONValue {
        if result.isError {
            await update(id, ClaudeStreamTranslator.chunk("agent_message_chunk", "\n\n⚠️ \(result.message)", nil))
        }
        if !result.permissionDenials.isEmpty {
            let names = Set(result.permissionDenials).sorted().joined(separator: "、")
            await update(id, ClaudeStreamTranslator.chunk("agent_message_chunk", "\n\n以下工具因权限被拒绝:\(names)。直连通道无法弹出审批,请在模式中选择 Accept edits / Bypass permissions,或在权限设置里加入允许规则后重试。", nil))
        }
        var usage: [String: JSONValue] = ["sessionUpdate": "usage_update", "used": .int(result.usedTokens)]
        if let cost = result.costUSD { usage["cost"] = ["amount": .double(cost), "currency": "USD"] }
        await update(id, .object(usage))
        return ["stopReason": .string(result.stopReason)]
    }
}
