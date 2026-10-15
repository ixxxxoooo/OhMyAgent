// @author ygw
// 把 `claude -p --output-format stream-json` 的事件翻译成 ACP `session/update`,供直连兜底通道复用同一套界面事件模型。

import ACPKit
import Foundation

/// 翻译产出。
public enum DirectOutput: Sendable, Equatable {
    /// 一条 `session/update` 的 `update` 载荷
    case update(JSONValue)
    /// claude 报告的会话 ID
    case sessionId(String)
    /// 本轮结束
    case finished(DirectResult)
}

/// 本轮结果。
public struct DirectResult: Sendable, Equatable {
    public var isError: Bool
    public var message: String
    public var stopReason: String
    public var usedTokens: Int
    public var costUSD: Double?
    public var permissionDenials: [String]
}

/// 流事件翻译器(有状态:记录已流式输出的内容,避免随后的完整消息重复展示)。
public struct ClaudeStreamTranslator: Sendable {
    /// 当前这条消息是否已经通过 partial 增量输出过文本 / 思维
    private var streamedText = false
    private var streamedThinking = false
    /// 已登记的工具调用:id → (名称, 输入)
    private var tools: [String: (name: String, input: JSONValue)] = [:]

    public init() {}

    /// 翻译一行事件。
    /// - Parameter event: 已解析的 JSON 事件
    /// - Returns: 零到多条产出
    public mutating func translate(_ event: JSONValue) -> [DirectOutput] {
        switch event["type"]?.stringValue {
        case "system": return translateSystem(event)
        case "stream_event": return translatePartial(event)
        case "assistant": return translateAssistant(event)
        case "user": return translateUser(event)
        case "result": return [.finished(Self.parseResult(event))]
        default: return []
        }
    }

    // MARK: - system / partial

    private func translateSystem(_ event: JSONValue) -> [DirectOutput] {
        guard event["subtype"]?.stringValue == "init", let id = event["session_id"]?.stringValue else { return [] }
        return [.sessionId(id)]
    }

    private mutating func translatePartial(_ event: JSONValue) -> [DirectOutput] {
        guard let inner = event["event"] else { return [] }
        let meta = Self.meta(event)
        switch inner["type"]?.stringValue {
        case "message_start":
            streamedText = false
            streamedThinking = false
            return []
        case "content_block_delta":
            let delta = inner["delta"]
            if delta?["type"]?.stringValue == "text_delta", let text = delta?["text"]?.stringValue {
                streamedText = true
                return [.update(Self.chunk("agent_message_chunk", text, meta))]
            }
            if delta?["type"]?.stringValue == "thinking_delta", let text = delta?["thinking"]?.stringValue {
                streamedThinking = true
                return [.update(Self.chunk("agent_thought_chunk", text, meta))]
            }
            return []
        default:
            return []
        }
    }

    // MARK: - assistant / user

    private mutating func translateAssistant(_ event: JSONValue) -> [DirectOutput] {
        var outputs: [DirectOutput] = []
        let meta = Self.meta(event)
        for block in event["message"]?["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if !streamedText, let text = block["text"]?.stringValue, !text.isEmpty { outputs.append(.update(Self.chunk("agent_message_chunk", text, meta))) }
            case "thinking":
                if !streamedThinking, let text = block["thinking"]?.stringValue, !text.isEmpty { outputs.append(.update(Self.chunk("agent_thought_chunk", text, meta))) }
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                let input = block["input"] ?? .object([:])
                tools[id] = (name, input)
                if name == "TodoWrite", let plan = Self.plan(from: input) { outputs.append(.update(plan)) }
                outputs.append(.update(Self.toolCall(id: id, name: name, input: input, meta: meta)))
            default:
                break
            }
        }
        streamedText = false
        streamedThinking = false
        return outputs
    }

    private mutating func translateUser(_ event: JSONValue) -> [DirectOutput] {
        var outputs: [DirectOutput] = []
        let content = event["message"]?["content"]
        guard let blocks = content?.arrayValue else { return [] }
        for block in blocks where block["type"]?.stringValue == "tool_result" {
            guard let id = block["tool_use_id"]?.stringValue else { continue }
            let failed = block["is_error"]?.boolValue ?? false
            var update: [String: JSONValue] = ["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": failed ? "failed" : "completed"]
            var items: [JSONValue] = []
            if let tool = tools[id], !failed, let diff = Self.diff(name: tool.name, input: tool.input) { items.append(diff) }
            let text = Self.resultText(block["content"])
            if !text.isEmpty { items.append(["type": "content", "content": ["type": "text", "text": .string(text)]]) }
            if !items.isEmpty { update["content"] = .array(items) }
            if let meta = Self.meta(event) { update["_meta"] = meta }
            outputs.append(.update(.object(update)))
        }
        return outputs
    }

    // MARK: - 构造辅助

    /// 子 Agent 的消息带有 `parent_tool_use_id`,映射为适配器同款 `_meta`。
    static func meta(_ event: JSONValue) -> JSONValue? {
        guard let parent = event["parent_tool_use_id"]?.stringValue, !parent.isEmpty else { return nil }
        return ["claudeCode": ["parentToolUseId": .string(parent)]]
    }

    static func chunk(_ kind: String, _ text: String, _ meta: JSONValue?) -> JSONValue {
        var value: [String: JSONValue] = ["sessionUpdate": .string(kind), "content": ["type": "text", "text": .string(text)]]
        if let meta { value["_meta"] = meta }
        return .object(value)
    }

    /// 工具名 → ACP 工具种类。
    static func kind(of name: String) -> String {
        switch name {
        case "Read": return "read"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "edit"
        case "Bash", "BashOutput", "KillShell": return "execute"
        case "Grep", "Glob", "LS": return "search"
        case "WebFetch", "WebSearch": return "fetch"
        case "Task", "Agent": return "think"
        default: return "other"
        }
    }

    /// 工具调用标题。
    static func title(name: String, input: JSONValue) -> String {
        func short(_ text: String, _ limit: Int = 80) -> String { text.count > limit ? String(text.prefix(limit)) + "…" : text }
        if let command = input["command"]?.stringValue { return "\(name): \(short(command))" }
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue { return "\(name) \((path as NSString).lastPathComponent)" }
        if let pattern = input["pattern"]?.stringValue { return "\(name) \(short(pattern, 40))" }
        if let url = input["url"]?.stringValue { return "\(name) \(short(url, 60))" }
        if let description = input["description"]?.stringValue { return "\(name): \(short(description))" }
        return name
    }

    static func toolCall(id: String, name: String, input: JSONValue, meta: JSONValue?) -> JSONValue {
        var value: [String: JSONValue] = [
            "sessionUpdate": "tool_call", "toolCallId": .string(id), "title": .string(title(name: name, input: input)),
            "kind": .string(kind(of: name)), "status": "in_progress", "rawInput": input,
        ]
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue { value["locations"] = [["path": .string(path)]] }
        if let meta { value["_meta"] = meta }
        return .object(value)
    }

    /// Edit / Write 的 diff(与适配器一致:Edit 为被替换片段)。
    static func diff(name: String, input: JSONValue) -> JSONValue? {
        guard let path = input["file_path"]?.stringValue else { return nil }
        switch name {
        case "Edit":
            return ["type": "diff", "path": .string(path), "oldText": .string(input["old_string"]?.stringValue ?? ""), "newText": .string(input["new_string"]?.stringValue ?? "")]
        case "Write":
            return ["type": "diff", "path": .string(path), "oldText": .null, "newText": .string(input["content"]?.stringValue ?? "")]
        default:
            return nil
        }
    }

    /// TodoWrite → ACP plan。
    static func plan(from input: JSONValue) -> JSONValue? {
        guard let todos = input["todos"]?.arrayValue else { return nil }
        let entries = todos.compactMap { item -> JSONValue? in
            guard let content = item["content"]?.stringValue else { return nil }
            return ["content": .string(content), "priority": "medium", "status": .string(item["status"]?.stringValue ?? "pending")]
        }
        return ["sessionUpdate": "plan", "entries": .array(entries)]
    }

    /// tool_result 的内容可能是字符串或块数组。
    static func resultText(_ content: JSONValue?) -> String {
        if let text = content?.stringValue { return text }
        return (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    static func parseResult(_ event: JSONValue) -> DirectResult {
        let usage = event["usage"]
        func tokens(_ key: String) -> Int { usage?[key]?.intValue ?? 0 }
        let used = tokens("input_tokens") + tokens("cache_read_input_tokens") + tokens("cache_creation_input_tokens") + tokens("output_tokens")
        let denials = (event["permission_denials"]?.arrayValue ?? []).compactMap { $0["tool_name"]?.stringValue }
        let isError = event["is_error"]?.boolValue ?? (event["subtype"]?.stringValue != "success")
        let subtype = event["subtype"]?.stringValue ?? ""
        let reason = subtype == "error_max_turns" ? "max_turn_requests" : "end_turn"
        return DirectResult(isError: isError, message: event["result"]?.stringValue ?? subtype, stopReason: reason,
                            usedTokens: used, costUSD: event["total_cost_usd"]?.doubleValue, permissionDenials: denials)
    }
}
