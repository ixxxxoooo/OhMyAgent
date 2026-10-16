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
    /// 正在处理提示的会话
    private var running: Set<String> = []
    /// 各会话收到的引导消息
    private var steered: [String: [String]] = [:]
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
            if method == "session/load" {
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

    /// 长时间占用场景(`#hold`):同时挂起一个运行约 20 秒的终端与一个未完成的子 Agent,用于验证输入栏任务坞。
    private func runHold(sessionId: String) async throws {
        let meta: JSONValue = ["claudeCode": ["parentToolUseId": "hold_sub"]]
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "hold_sub", "title": "子任务:长时间调研", "kind": "other", "status": "in_progress"])
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "hold_read", "title": "读取 Package.swift", "kind": "read", "status": "completed", "_meta": meta])
        await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "子 Agent 正在调研…"], "_meta": meta])
        if clientTerminal {
            let created = try await connection.request("terminal/create", params: [
                "sessionId": .string(sessionId), "command": "sh", "args": ["-c", "echo start; for i in 1 2 3 4 5 6 7 8 9 10; do echo tick-$i; sleep 2; done"],
            ])
            let terminalId = created["terminalId"]?.stringValue ?? ""
            await update(sessionId, [
                "sessionUpdate": "tool_call", "toolCallId": "hold_term", "title": "运行长命令", "kind": "execute", "status": "in_progress",
                "content": [["type": "terminal", "terminalId": .string(terminalId)]],
            ])
            _ = try await connection.request("terminal/wait_for_exit", params: ["sessionId": .string(sessionId), "terminalId": .string(terminalId)])
            await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "hold_term", "status": "completed"])
        }
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "hold_sub", "status": "completed"])
    }

    /// Mermaid 场景:依次输出流程图、时序图、状态图、类图、饼图、甘特图与一个不支持的类型(验证回退)。
    private func runMermaid(sessionId: String) async {
        let blocks = [
            "```mermaid\nflowchart TD\n  A[用户请求] --> B{已登录?}\n  B -->|是| C[读取数据]\n  B -->|否| D[跳转登录]\n  D --> A\n  C --> E([完成])\n  subgraph 后端\n    C --> F[(数据库)]\n  end\n```\n\n",
            "```mermaid\nsequenceDiagram\n  autonumber\n  participant U as 用户\n  participant S as 服务\n  U->>+S: 发起请求\n  S-->>-U: 返回结果\n  Note over U,S: 完成\n  loop 每分钟\n    U->>U: 自检\n  end\n```\n\n",
            "```mermaid\nstateDiagram-v2\n  [*] --> Idle\n  Idle --> Running : start\n  Running --> Idle : stop\n  Running --> [*]\n```\n\n",
            "```mermaid\nclassDiagram\n  class Animal {\n    +String name\n    +eat() void\n  }\n  Animal <|-- Dog\n  Animal <|-- Cat\n```\n\n",
            "```mermaid\npie showData title 占比\n  \"甲\" : 30\n  \"乙\" : 50\n  \"丙\" : 20\n```\n\n",
            "```mermaid\ngantt\n  title 计划\n  dateFormat YYYY-MM-DD\n  section 设计\n  调研 :done, a1, 2026-01-01, 5d\n  方案 :a2, after a1, 3d\n  section 开发\n  实现 :crit, 2026-01-10, 2026-01-20\n```\n\n",
            "```mermaid\nerDiagram\n  A ||--o{ B : has\n```\n\n",
        ]
        for block in blocks {
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(block)]])
        }
    }

    /// 子 Agent:父工具调用 + 带 `parentToolUseId` 的内部更新;`#sub2` 额外产生第二层子 Agent。
    private func runSubagent(sessionId: String, nested: Bool = false) async {
        let meta: JSONValue = ["claudeCode": ["parentToolUseId": "sub_1"]]
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub_1", "title": "子任务:调研代码", "kind": "other", "status": "in_progress"])
        await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub_read", "title": "读取 README.md", "kind": "read", "status": "completed", "_meta": meta])
        await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "子 Agent 的中间结论。"], "_meta": meta])
        if nested {
            let inner: JSONValue = ["claudeCode": ["parentToolUseId": "sub_2"]]
            await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub_2", "title": "子任务:分析依赖", "kind": "other", "status": "in_progress", "_meta": meta])
            await update(sessionId, ["sessionUpdate": "tool_call", "toolCallId": "sub2_grep", "title": "搜索 import", "kind": "search", "status": "completed", "_meta": inner])
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "第二层子 Agent 的结论。"], "_meta": inner])
            await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "sub_2", "status": "completed", "_meta": meta])
        }
        await update(sessionId, ["sessionUpdate": "tool_call_update", "toolCallId": "sub_1", "status": "completed"])
    }

    // MARK: 工具展示场景(`#showcase`:覆盖读/搜/写/改/终端/MCP/联网/失败,无需权限)

    /// 发送一次完整的工具调用:进行中 → 完成(或失败)。
    private func emitTool(
        _ sessionId: String, id: String, title: String, kind: String, name: String,
        input: JSONValue, output: String? = nil, extra: [JSONValue] = [], fail: Bool = false,
        locations: JSONValue = .array([])
    ) async {
        await update(sessionId, [
            "sessionUpdate": "tool_call", "toolCallId": .string(id), "title": .string(title), "kind": .string(kind),
            "name": .string(name), "status": "in_progress", "rawInput": input, "locations": locations,
        ])
        await pause()
        var content = extra
        if let output { content.append(["type": "content", "content": ["type": "text", "text": .string(output)]]) }
        await update(sessionId, [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(id),
            "status": fail ? "failed" : "completed", "content": .array(content),
        ])
        await pause()
    }

    /// 覆盖各类工具的展示场景。
    private func runToolsShowcase(sessionId: String) async {
        let cwd = sessions[sessionId] ?? "/tmp"
        let main = cwd + "/Sources/App/main.swift"
        await emitTool(sessionId, id: "t_read1", title: "读取 main.swift", kind: "read", name: "Read",
                       input: ["file_path": .string(main), "offset": 10, "limit": 50],
                       output: "let app = App()\napp.run()", locations: [["path": .string(main), "line": 10]])
        await emitTool(sessionId, id: "t_read2", title: "读取 Package.swift", kind: "read", name: "Read",
                       input: ["file_path": .string(cwd + "/Package.swift")], output: "// swift-tools-version: 6.4")
        await emitTool(sessionId, id: "t_grep", title: "搜索 TODO", kind: "search", name: "Grep",
                       input: ["pattern": "TODO", "path": .string(cwd + "/Sources")],
                       output: "\(main):12:    // TODO: 处理错误\n\(cwd)/Sources/App/Util.swift:40:    // TODO: 缓存\n\(cwd)/Sources/App/Model.swift:7:// TODO(ygw): 拆分")
        await emitTool(sessionId, id: "t_glob", title: "查找 *.swift", kind: "search", name: "Glob",
                       input: ["pattern": "**/*.swift"], output: "\(main)\n\(cwd)/Sources/App/Util.swift\n\(cwd)/Package.swift")
        await emitTool(sessionId, id: "t_write", title: "写入 NOTES.md", kind: "edit", name: "Write",
                       input: ["file_path": .string(cwd + "/NOTES.md")],
                       extra: [["type": "diff", "path": .string(cwd + "/NOTES.md"), "newText": "# 笔记\n\n- 第一条\n- 第二条\n"]],
                       locations: [["path": .string(cwd + "/NOTES.md")]])
        await emitTool(sessionId, id: "t_edit", title: "编辑 main.swift", kind: "edit", name: "Edit",
                       input: ["file_path": .string(main)],
                       extra: [["type": "diff", "path": .string(main), "oldText": "let app = App(debug: false)\napp.run()\n", "newText": "let app = App(debug: true)\napp.configure()\napp.run()\n"]],
                       locations: [["path": .string(main), "line": 1]])
        await emitTool(sessionId, id: "t_bash", title: "运行 swift test", kind: "execute", name: "Bash",
                       input: ["command": "swift test --filter Tool", "description": "运行工具相关测试"],
                       output: "\u{1B}[32m✔\u{1B}[0m Test one passed\n\u{1B}[31m✘\u{1B}[0m Test two failed\n\u{1B}[1;33mwarning:\u{1B}[0m something\nexit 1")
        await emitTool(sessionId, id: "t_mcp", title: "mcp__github__create_issue", kind: "other", name: "mcp__github__create_issue",
                       input: ["title": "修复崩溃", "repo": "ygw/demo"], output: "{\"number\": 42}")
        await emitTool(sessionId, id: "t_fetch", title: "获取 example.com", kind: "fetch", name: "WebFetch",
                       input: ["url": "https://example.com/docs"], output: "Example Domain")
        await emitTool(sessionId, id: "t_fail", title: "运行 false", kind: "execute", name: "Bash",
                       input: ["command": "false"], output: "command failed with exit code 1", fail: true)
    }

    private func runPrompt(_ p: JSONValue) async throws -> JSONValue {
        guard let sessionId = p["sessionId"]?.stringValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "缺少 sessionId")
        }
        cancelled.remove(sessionId)
        running.insert(sessionId)
        defer { running.remove(sessionId) }
        let text = (p["prompt"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        if text.contains("#notice") {
            await update(sessionId, ["sessionUpdate": "notice", "severity": "warning", "title": "上下文已压缩", "description": "旧消息已被摘要,可能丢失细节。"])
        }

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
        if text.contains("#hold") { try await runHold(sessionId: sessionId) }
        if text.contains("#sub") { await runSubagent(sessionId: sessionId, nested: text.contains("#sub2")) }
        if text.contains("#showcase") { await runToolsShowcase(sessionId: sessionId) }
        if text.contains("#mermaid") { await runMermaid(sessionId: sessionId) }

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
            ? Array(repeating: "慢速输出分片。", count: text.contains("#long") ? 400 : 60)
            : ["你好,", "这是", "脚本化 ", "Agent ", "的回复:", text.isEmpty ? "(空)" : String(text.prefix(40))]
        for piece in reply {
            if cancelled.contains(sessionId) { return ["stopReason": "cancelled"] }
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(piece)]])
            try? await Task.sleep(for: .milliseconds(max(chunkDelayMillis, text.contains("slow") ? 40 : 0)))
        }
        for extra in steered.removeValue(forKey: sessionId) ?? [] {
            await update(sessionId, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("(已收到引导:\(extra))")]])
        }
        await update(sessionId, ["sessionUpdate": "usage_update", "used": 1200, "size": 200_000, "cost": ["amount": 0.0123, "currency": "USD"]])
        return ["stopReason": "end_turn"]
    }
}
