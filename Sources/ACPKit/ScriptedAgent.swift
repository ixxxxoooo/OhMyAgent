// @author ixxxxoooo
// 脚本化 ACP Agent:用于协议测试、UI 预览与离线演示,行为由提示词关键字驱动。

import Foundation

/// 脚本化 Agent。支持流式文本、思维、工具调用 + 权限审批 + Diff、计划、取消。
public actor ScriptedAgent: ACPRequestHandler {
    public let connection: ACPConnection
    var cancelled: Set<String> = []
    var sessions: [String: String] = [:]
    var modes: [String: String] = [:]
    var models: [String: String] = [:]
    var sessionCounter = 0
    var editCounter = 0
    /// 演示场景运行序号(用于让每次运行的工具卡 ID 唯一)
    var demoRunCounter = 0
    /// 内置步骤(终端/长占用)序号,保证重复运行时工具卡 ID 唯一
    var builtinCounter = 0
    /// 正在处理提示的会话
    var running: Set<String> = []
    /// 各会话收到的引导消息
    var steered: [String: [String]] = [:]
    var clientTerminal = false
    /// 是否提供演示历史会话(`session/list` 返回目录、`session/load` 回放完整内容);演示模式开启
    let demoHistory: Bool
    /// 正在回放历史的会话(回放不做任何停顿)
    var replaying: Set<String> = []
    private var pump: Task<Void, Never>?
    /// 每个文本分片之间的停顿(毫秒),便于测试取消与流式合并。
    let chunkDelayMillis: Int
    private let onClose: (@Sendable () -> Void)?

    /// 创建脚本化 Agent。
    /// - Parameters:
    ///   - transport: 传输
    ///   - chunkDelayMillis: 分片间隔
    ///   - demoHistory: 是否提供演示历史会话目录
    ///   - onClose: 连接关闭回调
    public init(transport: any ACPTransport, chunkDelayMillis: Int = 15, demoHistory: Bool = false, onClose: (@Sendable () -> Void)? = nil) {
        self.demoHistory = demoHistory
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
                    "loadSession": true,
                    "promptCapabilities": ["image": true, "embeddedContext": true],
                    "mcpCapabilities": ["http": true, "sse": false],
                    "sessionCapabilities": ["list": .object([:]), "close": .object([:]), "resume": .object([:]), "fork": .object([:]), "delete": .object([:])],
                ],
                "agentInfo": ["name": "scripted-agent", "title": "Scripted Agent", "version": "0.1.0"],
                "authMethods": [["id": "fake-login", "name": "模拟登录", "description": "测试用"]],
                "_meta": ["steering": ["supported": true]],
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
            if demoHistory { return demoSessionList(cwd: p["cwd"]?.stringValue) }
            let list = sessions.keys.sorted().map { id -> JSONValue in ["sessionId": .string(id), "cwd": .string(sessions[id] ?? "/"), "title": .string("脚本会话 \(id)"), "updatedAt": "2026-10-16T01:00:00Z"] }
            return ["sessions": .array(list)]
        case "authenticate", "logout":
            return .object([:])
        case "session/load", "session/resume":
            guard let id = p["sessionId"]?.stringValue else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 sessionId")
            }
            sessions[id] = p["cwd"]?.stringValue ?? sessions[id] ?? "/"
            modes[id] = modes[id] ?? "default"
            models[id] = models[id] ?? "scripted-1"
            if method == "session/load", demoHistory, let history = DemoHistory.session(id: id) {
                await replayDemoHistory(history, cwd: sessions[id] ?? "/")
            } else if method == "session/load" {
                // 回放历史
                await update(id, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": .string("历史问题 \(id)")]])
                await update(id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "历史"]])
                await update(id, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "回答"]])
            }
            return ["configOptions": configOptions(sessionId: id)]
        case "session/fork":
            sessionCounter += 1
            let id = "scripted-\(sessionCounter)"
            sessions[id] = p["cwd"]?.stringValue ?? "/"
            modes[id] = "default"
            models[id] = "scripted-1"
            return ["sessionId": .string(id), "configOptions": configOptions(sessionId: id)]
        case "session/delete":
            if let id = p["sessionId"]?.stringValue { sessions[id] = nil }
            return .object([:])
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
        case "_session/steering":
            // 有运行中的轮次:记录引导消息并回显;否则要求调用方改走 session/prompt
            guard let id = p["sessionId"]?.stringValue, running.contains(id) else { return ["outcome": "promptRequired", "reason": "noRunningTurn"] }
            let text = (p["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            steered[id, default: []].append(text)
            return ["outcome": "injected"]
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
            "availableCommands": .array([
                ["name": "compact", "description": "压缩上下文", "input": JSONValue.null],
                ["name": "context", "description": "查看上下文用量", "input": JSONValue.null],
                ["name": "review", "description": "审查改动", "input": ["hint": "可选范围"]],
            ] + (demoHistory ? DemoScenarios.commandDescriptors : [])),
        ])
    }

    // MARK: 提示轮次

    func update(_ sessionId: String, _ update: JSONValue) async {
        await connection.notify("session/update", params: ["sessionId": .string(sessionId), "update": update])
    }

    func pause() async {
        try? await Task.sleep(for: .milliseconds(chunkDelayMillis))
    }

    // MARK: 扩展场景(真实写文件、提问、终端、子 Agent)

    /// 真实修改工作区内的 `oma-demo.txt`,用于验证检查点与改动汇总。
    func runEdit(sessionId: String) async throws {
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
    func runAsk(sessionId: String) async throws {
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
    func runTerminal(sessionId: String) async throws {
        guard clientTerminal else {
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "客户端未声明 terminal 能力。\n\n"]])
            return
        }
        builtinCounter += 1
        let toolId = "term_\(builtinCounter)"
        let created = try await connection.request("terminal/create", params: [
            "sessionId": .string(sessionId), "command": "sh", "args": ["-c", "echo hello-from-terminal; sleep 0.4; echo done"],
        ])
        let terminalId = created["terminalId"]?.stringValue ?? ""
        await update(sessionId, [
            "sessionUpdate": "tool_call", "toolCallId": .string(toolId), "title": "运行 echo", "kind": "execute", "status": "in_progress",
            "content": [["type": "terminal", "terminalId": .string(terminalId)]],
        ])
        _ = try await connection.request("terminal/wait_for_exit", params: ["sessionId": .string(sessionId), "terminalId": .string(terminalId)])
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": "completed"])
    }

    /// 长时间占用场景(`#hold`):同时挂起一个运行约 20 秒的终端与一个未完成的子 Agent,用于验证输入栏任务坞。
    func runHold(sessionId: String) async throws {
        builtinCounter += 1
        let n = builtinCounter
        let subId: JSONValue = .string("hold_sub_\(n)")
        let meta: JSONValue = ["claudeCode": ["parentToolUseId": subId]]
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": subId, "title": "子任务:长时间调研", "kind": "other", "status": "in_progress"])
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": .string("hold_read_\(n)"), "title": "读取 Package.swift", "kind": "read", "status": "completed", "_meta": meta])
        await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "子 Agent 正在调研…"], "_meta": meta])
        if clientTerminal {
            let created = try await connection.request("terminal/create", params: [
                "sessionId": .string(sessionId), "command": "sh", "args": ["-c", "echo start; for i in 1 2 3 4 5 6 7 8 9 10; do echo tick-$i; sleep 2; done"],
            ])
            let terminalId = created["terminalId"]?.stringValue ?? ""
            await update(sessionId, [
                "sessionUpdate": "tool_call", "toolCallId": .string("hold_term_\(n)"), "title": "运行长命令", "kind": "execute", "status": "in_progress",
                "content": [["type": "terminal", "terminalId": .string(terminalId)]],
            ])
            _ = try await connection.request("terminal/wait_for_exit", params: ["sessionId": .string(sessionId), "terminalId": .string(terminalId)])
            await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": .string("hold_term_\(n)"), "status": "completed"])
        }
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": subId, "status": "completed"])
    }

    /// `/context` 的模拟输出。
    static let contextReport = """
    ## Context Usage

    **Model:** scripted-1  
    **Tokens:** 62.4k / 200k (31%)

    ### Estimated usage by category

    | Category | Tokens | Percentage |
    |----------|--------|------------|
    | System prompt | 2.4k | 1.2% |
    | System tools | 7.2k | 3.6% |
    | Skills | 10.6k | 5.3% |
    | MCP tools | 13.4k | 6.7% |
    | Messages | 28.8k | 14.4% |
    | Free space | 105.6k | 52.8% |
    | Autocompact buffer | 32k | 16% |
    """

    private func runPrompt(_ p: JSONValue) async throws -> JSONValue {
        guard let sessionId = p["sessionId"]?.stringValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 sessionId")
        }
        cancelled.remove(sessionId)
        running.insert(sessionId)
        defer { running.remove(sessionId) }
        let text = (p["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/context" {
            // 模拟 Claude 的本地命令:不调用模型,直接输出 Markdown 明细(格式与真实抓取一致)
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(Self.contextReport)]])
            return ["stopReason": "end_turn"]
        }
        if text.contains("#notice") {
            await update(sessionId, ["sessionUpdate": "notice", "severity": "warning", "title": "上下文已压缩", "description": "旧消息已被摘要,可能丢失细节。"])
        }

        // 思维
        for piece in ["让我先想想", ",这个请求需要", "分步骤处理。"] {
            await update(sessionId, ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": .string(piece)]])
            await pause()
            if cancelled.contains(sessionId) { return ["stopReason": "cancelled"] }
        }

        // 场景目录:旧关键字(#sub / #showcase / #mermaid)与 `#demo-<场景名>`
        let matches = DemoScenarios.matching(prompt: text)
        let isDemo = matches.contains { $0.isDemo }

        if !isDemo, text.contains("tool") || text.contains("工具") {
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
        if text.contains("#hold") { try await runHold(sessionId: sessionId) }
        if isDemo { demoRunCounter += 1 }
        let context = ScenarioContext(cwd: sessions[sessionId] ?? "/tmp", sessionId: sessionId, idSuffix: isDemo ? "-r\(demoRunCounter)" : "")
        for match in matches {
            let outcome = try await runSteps(match.scenario.build(context), ctx: context)
            if outcome == .cancelled { return ["stopReason": "cancelled"] }
            if outcome == .rejected { return ["stopReason": "end_turn"] }
        }

        if !isDemo, text.contains("plan") || text.contains("计划") {
            await update(sessionId, [
                "sessionUpdate": "plan",
                "entries": [
                    ["content": "阅读代码", "priority": "high", "status": "completed"],
                    ["content": "实现功能", "priority": "high", "status": "in_progress"],
                    ["content": "补充测试", "priority": "medium", "status": "pending"],
                ],
            ])
        }

        // 演示场景自带回复文本,不再追加默认回显
        if isDemo { return await finishTurn(sessionId: sessionId, defaultUsage: false) }

        // 文本流
        let reply = text.contains("slow")
            ? Array(repeating: "慢速输出分片。", count: text.contains("#long") ? 400 : 60)
            : ["你好,", "这是", "脚本化 ", "Agent ", "的回复:", text.isEmpty ? "(空)" : String(text.prefix(40))]
        for piece in reply {
            if cancelled.contains(sessionId) { return ["stopReason": "cancelled"] }
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(piece)]])
            try? await Task.sleep(for: .milliseconds(max(chunkDelayMillis, text.contains("slow") ? 40 : 0)))
        }
        return await finishTurn(sessionId: sessionId)
    }

    /// 轮次收尾:补发已收到的引导回显与用量,返回正常结束。
    private func finishTurn(sessionId: String, defaultUsage: Bool = true) async -> JSONValue {
        for extra in steered.removeValue(forKey: sessionId) ?? [] {
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("(已收到引导:\(extra))")]])
        }
        if defaultUsage { await update(sessionId, ["sessionUpdate": "usage_update", "used": 1200, "size": 200_000, "cost": ["amount": 0.0123, "currency": "USD"]]) }
        // 与真实适配器一致:响应里带本轮 token 用量(回合结束摘要据此显示 token 与 tps)
        return ["stopReason": "end_turn", "usage": ["inputTokens": 1200, "outputTokens": 360, "cachedReadTokens": 0, "cachedWriteTokens": 0, "totalTokens": 1560]]
    }
}
