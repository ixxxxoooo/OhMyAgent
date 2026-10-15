// @author ygw
// 脚本化 ACP Agent:用于协议测试、UI 预览与离线演示,行为由提示词关键字驱动。

import Foundation

/// 脚本化 Agent。支持流式文本、思维、工具调用 + 权限审批 + Diff、计划、取消。
public actor ScriptedAgent: ACPRequestHandler {
    public let connection: ACPConnection
    private var cancelled: Set<String> = []
    private var sessions: [String: String] = [:]
    private var modes: [String: String] = [:]
    private var models: [String: String] = [:]
    private var sessionCounter = 0
    private var pump: Task<Void, Never>?
    /// 每个文本分片之间的停顿(毫秒),便于测试取消与流式合并。
    private let chunkDelayMillis: Int
    private let onClose: (@Sendable () -> Void)?

    /// 创建脚本化 Agent。
    /// - Parameters:
    ///   - transport: 传输
    ///   - chunkDelayMillis: 分片间隔
    ///   - onClose: 连接关闭回调
    public init(transport: any ACPTransport, chunkDelayMillis: Int = 15, onClose: (@Sendable () -> Void)? = nil) {
        self.onClose = onClose
        self.connection = ACPConnection(transport: transport)
        self.chunkDelayMillis = chunkDelayMillis
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
                    if method == "session/cancel", let id = params?["sessionId"]?.stringValue {
                        await self?.markCancelled(id)
                    }
                case .closed:
                    await self?.notifyClosed()
                default:
                    break
                }
            }
        }
    }

    private func markCancelled(_ id: String) { cancelled.insert(id) }

    private func notifyClosed() { onClose?() }

    // MARK: 请求处理

    public func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        let p = params ?? .null
        switch method {
        case "initialize":
            return [
                "protocolVersion": 1,
                "agentCapabilities": [
                    "loadSession": false,
                    "promptCapabilities": ["image": true, "embeddedContext": true],
                    "mcpCapabilities": ["http": true, "sse": false],
                    "sessionCapabilities": ["list": .object([:]), "close": .object([:]), "resume": .object([:])],
                ],
                "agentInfo": ["name": "scripted-agent", "title": "Scripted Agent", "version": "0.1.0"],
                "authMethods": [],
            ]
        case "session/new":
            sessionCounter += 1
            let id = "scripted-\(sessionCounter)"
            sessions[id] = p["cwd"]?.stringValue ?? "/"
            modes[id] = "default"
            models[id] = "scripted-1"
            Task { await self.sendCommands(sessionId: id) }
            return ["sessionId": .string(id), "configOptions": configOptions(sessionId: id)]
        case "session/list":
            let list = sessions.map { (id, cwd) -> JSONValue in ["sessionId": .string(id), "cwd": .string(cwd), "title": .string("脚本会话 \(id)")] }
            return ["sessions": .array(list)]
        case "session/close":
            if let id = p["sessionId"]?.stringValue { cancelled.insert(id); sessions[id] = nil }
            return .object([:])
        case "session/set_mode":
            if let id = p["sessionId"]?.stringValue, let mode = p["modeId"]?.stringValue { modes[id] = mode }
            return .object([:])
        case "session/set_config_option":
            guard let id = p["sessionId"]?.stringValue, let configId = p["configId"]?.stringValue, let value = p["value"]?.stringValue else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少参数")
            }
            if configId == "mode" { modes[id] = value } else if configId == "model" { models[id] = value }
            return ["configOptions": configOptions(sessionId: id)]
        case "session/prompt":
            return try await runPrompt(p)
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "ScriptedAgent 未实现 \(method)")
        }
    }

    private func configOptions(sessionId: String) -> JSONValue {
        [
            [
                "id": "mode", "name": "Mode", "category": "mode", "type": "select",
                "currentValue": .string(modes[sessionId] ?? "default"),
                "options": [
                    ["value": "default", "name": "Manual"],
                    ["value": "acceptEdits", "name": "Accept edits"],
                    ["value": "plan", "name": "Plan"],
                ],
            ],
            [
                "id": "model", "name": "Model", "category": "model", "type": "select",
                "currentValue": .string(models[sessionId] ?? "scripted-1"),
                "options": [
                    ["value": "scripted-1", "name": "Scripted 1"],
                    ["value": "scripted-2", "name": "Scripted 2"],
                ],
            ],
        ]
    }

    private func sendCommands(sessionId: String) async {
        await update(sessionId, [
            "sessionUpdate": "available_commands_update",
            "availableCommands": [
                ["name": "compact", "description": "压缩上下文", "input": JSONValue.null],
                ["name": "review", "description": "审查改动", "input": ["hint": "可选范围"]],
            ],
        ])
    }

    // MARK: 提示轮次

    private func update(_ sessionId: String, _ update: JSONValue) async {
        await connection.notify("session/update", params: ["sessionId": .string(sessionId), "update": update])
    }

    private func pause() async {
        try? await Task.sleep(for: .milliseconds(chunkDelayMillis))
    }

    private func runPrompt(_ p: JSONValue) async throws -> JSONValue {
        guard let sessionId = p["sessionId"]?.stringValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 sessionId")
        }
        cancelled.remove(sessionId)
        let text = (p["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")

        // 思维
        for piece in ["让我先想想", ",这个请求需要", "分步骤处理。"] {
            await update(sessionId, ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": .string(piece)]])
            await pause()
            if cancelled.contains(sessionId) { return ["stopReason": "cancelled"] }
        }

        if text.contains("tool") || text.contains("工具") {
            // 工具调用 + 权限 + Diff
            await update(sessionId, [
                "sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "修改 config.json", "kind": "edit", "status": "pending",
                "locations": [["path": "/tmp/config.json", "line": 1]],
                "rawInput": ["path": "/tmp/config.json"],
            ])
            let permission = try await connection.request("session/request_permission", params: [
                "sessionId": .string(sessionId),
                "toolCall": ["toolCallId": "call_1", "title": "修改 config.json", "kind": "edit"],
                "options": [
                    ["optionId": "allow", "name": "允许一次", "kind": "allow_once"],
                    ["optionId": "reject", "name": "拒绝", "kind": "reject_once"],
                ],
            ])
            let outcome = permission["outcome"]?["outcome"]?.stringValue
            let optionId = permission["outcome"]?["optionId"]?.stringValue
            if outcome == "cancelled" || cancelled.contains(sessionId) {
                await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "failed"])
                return ["stopReason": "cancelled"]
            }
            if optionId == "reject" {
                await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "failed"])
                await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "已取消修改。"]])
                return ["stopReason": "end_turn"]
            }
            await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "in_progress"])
            await pause()
            await update(sessionId, [
                "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "completed",
                "content": [["type": "diff", "path": "/tmp/config.json", "oldText": "{\n  \"debug\": false\n}", "newText": "{\n  \"debug\": true\n}"]],
            ])
        }

        if text.contains("plan") || text.contains("计划") {
            await update(sessionId, [
                "sessionUpdate": "plan",
                "entries": [
                    ["content": "阅读代码", "priority": "high", "status": "completed"],
                    ["content": "实现功能", "priority": "high", "status": "in_progress"],
                    ["content": "补充测试", "priority": "medium", "status": "pending"],
                ],
            ])
        }

        // 文本流
        let reply = text.contains("slow")
            ? Array(repeating: "慢速输出分片。", count: 60)
            : ["你好,", "这是", "脚本化 ", "Agent ", "的回复:", text.isEmpty ? "(空)" : String(text.prefix(40))]
        for piece in reply {
            if cancelled.contains(sessionId) { return ["stopReason": "cancelled"] }
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(piece)]])
            try? await Task.sleep(for: .milliseconds(max(chunkDelayMillis, text.contains("slow") ? 40 : 0)))
        }
        await update(sessionId, ["sessionUpdate": "usage_update", "used": 1200, "size": 200_000, "cost": ["amount": 0.0123, "currency": "USD"]])
        return ["stopReason": "end_turn"]
    }
}
