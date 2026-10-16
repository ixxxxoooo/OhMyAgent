// @author ixxxxoooo
// ACP v1 核心数据模型。解码一律宽松:未知字段忽略、未知枚举值保留,保证前向兼容。

import Foundation

// MARK: - 内容块

/// 内容块(文本、图片、音频、资源链接、内嵌资源)。
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    case image(data: String, mimeType: String, uri: String?)
    case audio(data: String, mimeType: String)
    case resourceLink(uri: String, name: String, mimeType: String?, title: String?)
    case resource(uri: String, text: String?, blob: String?, mimeType: String?)
    case unknown(JSONValue)

    /// 从 JSON 解析内容块。
    /// - Parameter json: JSON 对象
    public init(json: JSONValue) {
        let type = json["type"]?.stringValue ?? ""
        switch type {
        case "text":
            self = .text(json["text"]?.stringValue ?? "")
        case "image":
            self = .image(data: json["data"]?.stringValue ?? "", mimeType: json["mimeType"]?.stringValue ?? "image/png", uri: json["uri"]?.stringValue)
        case "audio":
            self = .audio(data: json["data"]?.stringValue ?? "", mimeType: json["mimeType"]?.stringValue ?? "audio/wav")
        case "resource_link":
            self = .resourceLink(uri: json["uri"]?.stringValue ?? "", name: json["name"]?.stringValue ?? "", mimeType: json["mimeType"]?.stringValue, title: json["title"]?.stringValue)
        case "resource":
            let resource = json["resource"] ?? .null
            self = .resource(uri: resource["uri"]?.stringValue ?? "", text: resource["text"]?.stringValue, blob: resource["blob"]?.stringValue, mimeType: resource["mimeType"]?.stringValue)
        default:
            self = .unknown(json)
        }
    }

    /// 序列化为协议 JSON。
    public var json: JSONValue {
        switch self {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType, let uri):
            var object: [String: JSONValue] = ["type": "image", "data": .string(data), "mimeType": .string(mimeType)]
            if let uri { object["uri"] = .string(uri) }
            return .object(object)
        case .audio(let data, let mimeType):
            return ["type": "audio", "data": .string(data), "mimeType": .string(mimeType)]
        case .resourceLink(let uri, let name, let mimeType, let title):
            var object: [String: JSONValue] = ["type": "resource_link", "uri": .string(uri), "name": .string(name)]
            if let mimeType { object["mimeType"] = .string(mimeType) }
            if let title { object["title"] = .string(title) }
            return .object(object)
        case .resource(let uri, let text, let blob, let mimeType):
            var resource: [String: JSONValue] = ["uri": .string(uri)]
            if let text { resource["text"] = .string(text) }
            if let blob { resource["blob"] = .string(blob) }
            if let mimeType { resource["mimeType"] = .string(mimeType) }
            return ["type": "resource", "resource": .object(resource)]
        case .unknown(let value):
            return value
        }
    }

    /// 文本内容(仅 `.text` 有值)。
    public var plainText: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

// MARK: - 工具调用

/// 工具类别。
public enum ToolKind: String, Sendable, Hashable {
    case read, edit, delete, move, search, execute, think, fetch
    case switchMode = "switch_mode"
    case other

    /// 宽松解析:未知值归为 `.other`。
    public init(rawOrOther raw: String?) {
        self = raw.flatMap(ToolKind.init(rawValue:)) ?? .other
    }
}

/// 工具调用状态。
public enum ToolStatus: String, Sendable, Hashable {
    case pending, inProgress = "in_progress", completed, failed

    public init(rawOrPending raw: String?) {
        self = raw.flatMap(ToolStatus.init(rawValue:)) ?? .pending
    }

    /// 是否已结束。
    public var isTerminal: Bool { self == .completed || self == .failed }
}

/// 工具调用产出的内容。
public enum ToolCallContent: Sendable, Hashable {
    case content(ContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    case unknown(JSONValue)

    public init(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "content":
            self = .content(ContentBlock(json: json["content"] ?? .null))
        case "diff":
            self = .diff(path: json["path"]?.stringValue ?? "", oldText: json["oldText"]?.stringValue, newText: json["newText"]?.stringValue ?? "")
        case "terminal":
            self = .terminal(terminalId: json["terminalId"]?.stringValue ?? "")
        default:
            self = .unknown(json)
        }
    }
}

/// 工具调用涉及的文件位置。
public struct ToolLocation: Sendable, Hashable {
    public var path: String
    public var line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// 一次工具调用的完整状态。
public struct ToolCall: Sendable, Hashable, Identifiable {
    public var id: String { toolCallId }
    public var toolCallId: String
    public var name: String?
    public var title: String
    public var kind: ToolKind
    public var status: ToolStatus
    public var content: [ToolCallContent]
    public var locations: [ToolLocation]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    /// 父工具调用 ID(子 Agent 内部的工具调用,来自 `_meta.claudeCode.parentToolUseId`)
    public var parentToolCallId: String?

    public init(toolCallId: String, name: String? = nil, title: String = "", kind: ToolKind = .other, status: ToolStatus = .pending, content: [ToolCallContent] = [], locations: [ToolLocation] = [], rawInput: JSONValue? = nil, rawOutput: JSONValue? = nil) {
        self.toolCallId = toolCallId
        self.name = name
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    /// 从 `tool_call` 更新解析。
    public init(json: JSONValue) {
        self.init(
            toolCallId: json["toolCallId"]?.stringValue ?? UUID().uuidString,
            name: json["name"]?.stringValue,
            title: json["title"]?.stringValue ?? "",
            kind: ToolKind(rawOrOther: json["kind"]?.stringValue),
            status: ToolStatus(rawOrPending: json["status"]?.stringValue),
            content: (json["content"]?.arrayValue ?? []).map(ToolCallContent.init(json:)),
            locations: Self.parseLocations(json["locations"]),
            rawInput: json["rawInput"].flatMap { $0.isNull ? nil : $0 },
            rawOutput: json["rawOutput"].flatMap { $0.isNull ? nil : $0 }
        )
        parentToolCallId = json["_meta"]?["claudeCode"]?["parentToolUseId"]?.stringValue
        if name == nil { name = json["_meta"]?["claudeCode"]?["toolName"]?.stringValue }
    }

    static func parseLocations(_ json: JSONValue?) -> [ToolLocation] {
        (json?.arrayValue ?? []).compactMap { item in
            guard let path = item["path"]?.stringValue else { return nil }
            return ToolLocation(path: path, line: item["line"]?.intValue)
        }
    }

    /// 应用增量更新:只覆盖更新中出现的字段。
    /// - Parameter update: `tool_call_update` 的 JSON
    public mutating func apply(update json: JSONValue) {
        if let value = json["name"]?.stringValue { name = value }
        if let value = json["title"]?.stringValue { title = value }
        if let value = json["kind"]?.stringValue { kind = ToolKind(rawOrOther: value) }
        if let value = json["status"]?.stringValue { status = ToolStatus(rawOrPending: value) }
        if let value = json["content"]?.arrayValue { content = value.map(ToolCallContent.init(json:)) }
        if json["locations"]?.arrayValue != nil { locations = Self.parseLocations(json["locations"]) }
        if let value = json["rawInput"], !value.isNull { rawInput = value }
        if let value = json["rawOutput"], !value.isNull { rawOutput = value }
        if let value = json["_meta"]?["claudeCode"]?["parentToolUseId"]?.stringValue { parentToolCallId = value }
        if name == nil, let value = json["_meta"]?["claudeCode"]?["toolName"]?.stringValue { name = value }
    }
}

// MARK: - 计划、命令、用量

/// 计划条目。
public struct PlanEntry: Sendable, Hashable {
    public var content: String
    public var priority: String
    public var status: String

    public init(content: String, priority: String = "medium", status: String = "pending") {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// 可用斜杠命令。
public struct AvailableCommand: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    /// 输入提示(无输入为 nil)
    public var inputHint: String?

    public init(name: String, description: String, inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

/// 用量更新。
public struct UsageUpdate: Sendable, Hashable {
    public var used: Int?
    public var size: Int?
    public var costAmount: Double?
    public var costCurrency: String?

    public init(used: Int? = nil, size: Int? = nil, costAmount: Double? = nil, costCurrency: String? = nil) {
        self.used = used
        self.size = size
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }
}

// MARK: - 会话配置

/// 配置选项的可选值。
public struct ConfigOptionValue: Sendable, Hashable {
    public var value: String
    public var name: String
    public var description: String?

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }
}

/// 会话配置选项(模型、模式、思考强度等)。
public struct SessionConfigOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    /// mode / model / thought_level 等
    public var category: String?
    /// select / boolean
    public var type: String
    public var currentValue: JSONValue
    public var options: [ConfigOptionValue]

    public init(json: JSONValue) {
        id = json["id"]?.stringValue ?? ""
        name = json["name"]?.stringValue ?? ""
        description = json["description"]?.stringValue
        category = json["category"]?.stringValue
        type = json["type"]?.stringValue ?? "select"
        currentValue = json["currentValue"] ?? .null
        var values: [ConfigOptionValue] = []
        for item in json["options"]?.arrayValue ?? [] {
            if let value = item["value"]?.stringValue {
                values.append(ConfigOptionValue(value: value, name: item["name"]?.stringValue ?? value, description: item["description"]?.stringValue))
            } else if let group = item["options"]?.arrayValue {
                // 分组选项:展平
                for sub in group {
                    if let value = sub["value"]?.stringValue {
                        values.append(ConfigOptionValue(value: value, name: sub["name"]?.stringValue ?? value, description: sub["description"]?.stringValue))
                    }
                }
            }
        }
        options = values
    }

    /// 当前值对应的显示名;当前值不在选项中(如网关自定义模型)时回退为原值。
    public var currentDisplayName: String {
        let raw = currentValue.stringValue ?? (currentValue.boolValue.map { $0 ? "开" : "关" } ?? "")
        return options.first { $0.value == raw }?.name ?? raw
    }
}

// MARK: - 会话更新

/// `session/update` 的各种变体。
public enum SessionUpdate: Sendable {
    case userMessageChunk(messageId: String?, content: ContentBlock)
    case agentMessageChunk(messageId: String?, content: ContentBlock)
    case agentThoughtChunk(messageId: String?, content: ContentBlock)
    case toolCall(ToolCall)
    /// 工具调用增量(含 toolCallId 的原始 JSON)
    case toolCallUpdate(toolCallId: String, raw: JSONValue)
    case plan([PlanEntry])
    case availableCommands([AvailableCommand])
    case currentMode(String)
    case configOptions([SessionConfigOption])
    case sessionInfo(title: String?, updatedAt: String?)
    case usage(UsageUpdate)
    /// 会话提示(需声明 `session.notices` 能力):严重程度 info/warning/error、标题、可选说明
    case notice(severity: String, title: String, detail: String?)
    /// 计划模式批准后的 Markdown 计划(`plan_update`)
    case planMarkdown(String)
    /// 适配器把扩展通知(如 pi-acp 转发的 pi `ctx.ui.notify`,例如 pi-tps 的「TPS …」行)当作消息分片发出,
    /// 但在 `_meta.piAcp.notify` 里标了级别。识别后不再拼进助手正文,由时间线单独成行。
    case agentNotify(level: String, text: String)
    /// 子 Agent(Task 工具)内部产生的更新,`parent` 为父工具调用 ID
    indirect case childUpdate(parent: String, update: SessionUpdate)
    case unknown(kind: String, raw: JSONValue)

    /// 解析 `params.update`。带有 `_meta.claudeCode.parentToolUseId` 的更新会被包装为 `.childUpdate`。
    /// - Parameter json: update 对象
    public init(json: JSONValue) {
        if let parent = json["_meta"]?["claudeCode"]?["parentToolUseId"]?.stringValue, !parent.isEmpty {
            self = .childUpdate(parent: parent, update: SessionUpdate(plain: json))
        } else {
            self.init(plain: json)
        }
    }

    /// 解析为普通更新(不检查父子关系)。
    init(plain json: JSONValue) {
        let kind = json["sessionUpdate"]?.stringValue ?? ""
        let messageId = json["messageId"]?.stringValue
        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(messageId: messageId, content: ContentBlock(json: json["content"] ?? .null))
        case "agent_message_chunk":
            if let notify = json["_meta"]?["piAcp"]?["notify"], case .text(let text) = ContentBlock(json: json["content"] ?? .null) {
                self = .agentNotify(level: notify["level"]?.stringValue ?? "info", text: text)
            } else {
                self = .agentMessageChunk(messageId: messageId, content: ContentBlock(json: json["content"] ?? .null))
            }
        case "agent_thought_chunk":
            self = .agentThoughtChunk(messageId: messageId, content: ContentBlock(json: json["content"] ?? .null))
        case "tool_call":
            self = .toolCall(ToolCall(json: json))
        case "tool_call_update":
            self = .toolCallUpdate(toolCallId: json["toolCallId"]?.stringValue ?? "", raw: json)
        case "plan":
            let entries = (json["entries"]?.arrayValue ?? []).map {
                PlanEntry(content: $0["content"]?.stringValue ?? "", priority: $0["priority"]?.stringValue ?? "medium", status: $0["status"]?.stringValue ?? "pending")
            }
            self = .plan(entries)
        case "available_commands_update":
            let commands = (json["availableCommands"]?.arrayValue ?? []).map {
                AvailableCommand(name: $0["name"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "", inputHint: $0["input"]?["hint"]?.stringValue)
            }
            self = .availableCommands(commands)
        case "current_mode_update":
            self = .currentMode(json["currentModeId"]?.stringValue ?? "")
        case "config_option_update", "config_options_update":
            self = .configOptions((json["configOptions"]?.arrayValue ?? []).map(SessionConfigOption.init(json:)))
        case "session_info_update":
            self = .sessionInfo(title: json["title"]?.stringValue, updatedAt: json["updatedAt"]?.stringValue)
        case "usage_update":
            self = .usage(UsageUpdate(
                used: json["used"]?.intValue,
                size: json["size"]?.intValue,
                costAmount: json["cost"]?["amount"]?.doubleValue,
                costCurrency: json["cost"]?["currency"]?.stringValue
            ))
        case "notice":
            self = .notice(
                severity: json["severity"]?.stringValue ?? "info",
                title: json["title"]?.stringValue ?? "",
                detail: json["description"]?.stringValue
            )
        case "plan_update":
            if json["plan"]?["type"]?.stringValue == "markdown", let content = json["plan"]?["content"]?.stringValue {
                self = .planMarkdown(content)
            } else {
                self = .unknown(kind: kind, raw: json)
            }
        default:
            self = .unknown(kind: kind, raw: json)
        }
    }
}

// MARK: - 权限

/// 权限选项类别。
public enum PermissionOptionKind: String, Sendable, Hashable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
    case other
}

/// 权限选项。
public struct PermissionOption: Sendable, Hashable, Identifiable {
    public var id: String { optionId }
    public var optionId: String
    public var name: String
    public var kind: PermissionOptionKind
}

/// 权限请求。
public struct PermissionRequest: Sendable {
    public var sessionId: String
    /// 触发请求的工具调用(可能只含 toolCallId 与部分字段)
    public var toolCallId: String
    public var toolCallRaw: JSONValue
    public var options: [PermissionOption]
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        sessionId = json["sessionId"]?.stringValue ?? ""
        toolCallRaw = json["toolCall"] ?? .null
        toolCallId = json["toolCall"]?["toolCallId"]?.stringValue ?? ""
        options = (json["options"]?.arrayValue ?? []).map {
            PermissionOption(
                optionId: $0["optionId"]?.stringValue ?? "",
                name: $0["name"]?.stringValue ?? "",
                kind: $0["kind"]?.stringValue.flatMap(PermissionOptionKind.init(rawValue:)) ?? .other
            )
        }
    }
}

/// 用户对权限请求的决定。
public enum PermissionOutcome: Sendable {
    case selected(optionId: String)
    case cancelled

    /// 序列化为响应 result。
    public var json: JSONValue {
        switch self {
        case .selected(let optionId):
            return ["outcome": ["outcome": "selected", "optionId": .string(optionId)]]
        case .cancelled:
            return ["outcome": ["outcome": "cancelled"]]
        }
    }
}

// MARK: - 会话信息

/// 一轮提示的 token 用量(`session/prompt` 响应里的 `usage`,适配器按轮累计)。
public struct TurnUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedReadTokens: Int
    public var cachedWriteTokens: Int
    public var totalTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedReadTokens: Int = 0, cachedWriteTokens: Int = 0, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.totalTokens = totalTokens ?? (inputTokens + outputTokens + cachedReadTokens + cachedWriteTokens)
    }

    /// 从响应 JSON 解析;缺少 `usage` 或所有计数都为 0 时返回 nil。
    /// - Parameter json: `session/prompt` 的 result 或其 `usage` 字段
    public init?(json: JSONValue?) {
        let node = json?["usage"] ?? json
        guard let node, node.objectValue != nil else { return nil }
        func count(_ key: String) -> Int { node[key]?.intValue ?? Int(node[key]?.doubleValue ?? 0) }
        let value = TurnUsage(inputTokens: count("inputTokens"), outputTokens: count("outputTokens"), cachedReadTokens: count("cachedReadTokens"),
                              cachedWriteTokens: count("cachedWriteTokens"), totalTokens: node["totalTokens"] != nil ? count("totalTokens") : nil)
        guard value.totalTokens > 0 || value.outputTokens > 0 else { return nil }
        self = value
    }
}

/// 停止原因。
public enum StopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
    case other
}

/// 历史会话摘要(`session/list`)。
public struct SessionSummary: Sendable, Hashable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var cwd: String
    public var title: String?
    public var updatedAt: String?

    public init(sessionId: String, cwd: String, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// MCP 服务器配置(用于 `session/new` 的 `mcpServers`)。
public enum MCPServerConfig: Sendable, Hashable {
    case stdio(name: String, command: String, args: [String], env: [String: String])
    case http(name: String, url: String, headers: [String: String])
    case sse(name: String, url: String, headers: [String: String])

    /// 序列化为协议 JSON。
    public var json: JSONValue {
        func pairs(_ dict: [String: String]) -> JSONValue {
            .array(dict.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string($0.value)] })
        }
        switch self {
        case .stdio(let name, let command, let args, let env):
            return ["name": .string(name), "command": .string(command), "args": .array(args.map(JSONValue.string)), "env": pairs(env)]
        case .http(let name, let url, let headers):
            return ["type": "http", "name": .string(name), "url": .string(url), "headers": pairs(headers)]
        case .sse(let name, let url, let headers):
            return ["type": "sse", "name": .string(name), "url": .string(url), "headers": pairs(headers)]
        }
    }
}
