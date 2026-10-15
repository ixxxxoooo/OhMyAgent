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
    private var editCounter = 0
    private var clientTerminal = false
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
            clientTerminal = p["clientCapabilities"]?["terminal"]?.boolValue ?? false
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

    // MARK: 扩展场景(真实写文件、提问、终端、子 Agent)

    /// 真实修改工作区内的 `oma-demo.txt`,用于验证检查点与改动汇总。
    private func runEdit(sessionId: String) async throws {
        let cwd = sessions[sessionId] ?? NSTemporaryDirectory()
        let path = (cwd as NSString).appendingPathComponent("oma-demo.txt")
        editCounter += 1
        let id = "edit_\(editCounter)"
        await update(sessionId, [
            "sessionUpdate": "tool_call", "toolCallId": .string(id), "title": "修改 oma-demo.txt", "kind": "edit", "status": "pending",
            "locations": [["path": .string(path)]],
        ])
        let permission = try await connection.request("session/request_permission", params: [
            "sessionId": .string(sessionId),
            "toolCall": [
                "toolCallId": .string(id), "title": "修改 oma-demo.txt", "kind": "edit",
                "content": [["type": "diff", "path": .string(path), "oldText": "line 3", "newText": "edited"]],
            ],
            "options": [
                ["optionId": "allow", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "reject", "name": "拒绝", "kind": "reject_once"],
            ],
        ])
        guard permission["outcome"]?["optionId"]?.stringValue == "allow" else {
            await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": "failed"])
            return
        }
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": "in_progress"])
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.count > 2 { lines[2] = "edited \(editCounter)" }
        lines.append("tail \(editCounter)")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        await update(sessionId, [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": "completed",
            "content": [["type": "diff", "path": .string(path), "oldText": "line 3", "newText": .string("edited \(editCounter)")]],
        ])
    }

    /// 发起 `elicitation/create` 表单(结构与 Claude 的 AskUserQuestion 一致)并回显答案。
    private func runAsk(sessionId: String) async throws {
        let answer = try await connection.request("elicitation/create", params: [
            "mode": "form",
            "sessionId": .string(sessionId),
            "message": "请选择实现方案",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "question_0": [
                        "type": "string", "title": "方案",
                        "oneOf": [
                            ["const": "A", "title": "方案 A", "description": "改动小"],
                            ["const": "B", "title": "方案 B", "description": "更彻底"],
                        ],
                    ],
                    "question_0_custom": ["type": "string", "title": "Other"],
                    "question_1": [
                        "type": "array", "title": "附加项",
                        "items": ["anyOf": [["const": "测试", "title": "测试"], ["const": "文档", "title": "文档"]]],
                    ],
                ],
            ],
        ])
        let summary = answer["action"]?.stringValue == "accept" ? (answer["content"]?.compactDescription ?? "{}") : "未回答"
        await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("收到答案:\(summary)\n\n")]])
    }

    /// 通过客户端终端执行命令(仅当客户端声明了 terminal 能力)。
    private func runTerminal(sessionId: String) async throws {
        guard clientTerminal else {
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "客户端未声明 terminal 能力。\n\n"]])
            return
        }
        let created = try await connection.request("terminal/create", params: [
            "sessionId": .string(sessionId), "command": "sh", "args": ["-c", "echo hello-from-terminal; sleep 0.4; echo done"],
        ])
        let terminalId = created["terminalId"]?.stringValue ?? ""
        await update(sessionId, [
            "sessionUpdate": "tool_call", "toolCallId": "term_1", "title": "运行 echo", "kind": "execute", "status": "in_progress",
            "content": [["type": "terminal", "terminalId": .string(terminalId)]],
        ])
        _ = try await connection.request("terminal/wait_for_exit", params: ["sessionId": .string(sessionId), "terminalId": .string(terminalId)])
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "term_1", "status": "completed"])
    }

    /// 子 Agent:父工具调用 + 带 `parentToolUseId` 的内部更新。
    private func runSubagent(sessionId: String) async {
        let meta: JSONValue = ["claudeCode": ["parentToolUseId": "sub_1"]]
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub_1", "title": "子任务:调研代码", "kind": "other", "status": "in_progress"])
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub_read", "title": "读取 README.md", "kind": "read", "status": "completed", "_meta": meta])
        await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "子 Agent 的中间结论。"], "_meta": meta])
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "sub_1", "status": "completed"])
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

        if text.contains("#edit") { try await runEdit(sessionId: sessionId) }
        if text.contains("#ask") { try await runAsk(sessionId: sessionId) }
        if text.contains("#term") { try await runTerminal(sessionId: sessionId) }
        if text.contains("#sub") { await runSubagent(sessionId: sessionId) }

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
