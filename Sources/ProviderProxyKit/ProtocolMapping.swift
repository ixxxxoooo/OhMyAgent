// @author ixxxxoooo
// Anthropic Messages ⇄ OpenAI Chat Completions 的协议映射(纯函数,无网络)。
//
// 覆盖:system、文本/图片、tool_use / tool_result、工具定义与 tool_choice、采样参数、
// 非流式响应与 stop_reason/usage 的回译。思考块(thinking)在请求方向丢弃。

import Foundation

/// 协议映射错误。
public enum ProxyMappingError: Error, Equatable, Sendable {
    /// 请求体不是合法的 Anthropic Messages JSON
    case invalidRequest
    /// 上游响应不是合法的 Chat Completions JSON
    case invalidResponse
}

/// 映射后的上游请求。
public struct MappedRequest: Sendable {
    /// OpenAI 请求体
    public var body: Data
    /// 是否流式
    public var stream: Bool
    /// 请求的模型名
    public var model: String
}

/// Anthropic ⇄ OpenAI 协议映射。
public enum ProtocolMapping {
    // MARK: - 请求方向

    /// 把 Anthropic `/v1/messages` 请求体转换为 OpenAI `/chat/completions` 请求体。
    /// - Parameter data: Anthropic 请求 JSON
    /// - Returns: 映射结果
    /// - Throws: `ProxyMappingError.invalidRequest`
    public static func openAIRequest(fromAnthropic data: Data) throws -> MappedRequest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawMessages = root["messages"] as? [[String: Any]] else { throw ProxyMappingError.invalidRequest }
        var messages: [[String: Any]] = []
        if let system = root["system"] {
            let text = systemText(system)
            if !text.isEmpty { messages.append(["role": "system", "content": text]) }
        }
        for message in rawMessages {
            let role = (message["role"] as? String) ?? "user"
            if let text = message["content"] as? String {
                messages.append(["role": role, "content": text])
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            if role == "assistant" {
                if let assistant = assistantMessage(blocks) { messages.append(assistant) }
            } else {
                messages.append(contentsOf: userMessages(blocks))
            }
        }
        let model = (root["model"] as? String) ?? ""
        let stream = (root["stream"] as? Bool) ?? false
        var out: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        if stream { out["stream_options"] = ["include_usage": true] }
        if let maxTokens = root["max_tokens"] as? Int, maxTokens > 0 { out["max_tokens"] = maxTokens }
        if let value = root["temperature"] as? Double { out["temperature"] = value }
        if let value = root["top_p"] as? Double { out["top_p"] = value }
        if let stops = root["stop_sequences"] as? [String], !stops.isEmpty { out["stop"] = Array(stops.prefix(4)) }
        if let tools = root["tools"] as? [[String: Any]] {
            let mapped = tools.compactMap(toolDefinition)
            if !mapped.isEmpty {
                out["tools"] = mapped
                if let choice = toolChoice(root["tool_choice"]) { out["tool_choice"] = choice }
            }
        }
        let body = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        return MappedRequest(body: body, stream: stream, model: model)
    }

    /// system 字段(字符串或文本块数组)转纯文本。
    static func systemText(_ value: Any) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    /// assistant 内容块 → OpenAI assistant 消息(文本 + tool_calls);无任何可见内容返回 nil。
    static func assistantMessage(_ blocks: [[String: Any]]) -> [String: Any]? {
        var text = ""
        var calls: [[String: Any]] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text": text += (block["text"] as? String) ?? ""
            case "tool_use":
                let input = block["input"] ?? [String: Any]()
                let arguments = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append([
                    "id": (block["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))",
                    "type": "function",
                    "function": ["name": (block["name"] as? String) ?? "", "arguments": arguments],
                ])
            default: break
            }
        }
        if text.isEmpty && calls.isEmpty { return nil }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { message["tool_calls"] = calls }
        return message
    }

    /// user 内容块 → 若干 OpenAI 消息:先是 tool 结果消息(必须紧跟 assistant 的 tool_calls),再是文本/图片。
    static func userMessages(_ blocks: [[String: Any]]) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        var parts: [[String: Any]] = []
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                tools.append([
                    "role": "tool",
                    "tool_call_id": (block["tool_use_id"] as? String) ?? "",
                    "content": toolResultText(block["content"], isError: (block["is_error"] as? Bool) ?? false),
                ])
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(["type": "text", "text": text]) }
            case "image":
                if let url = imageURL(block["source"]) { parts.append(["type": "image_url", "image_url": ["url": url]]) }
            default: break
            }
        }
        var result = tools
        if !parts.isEmpty {
            let onlyText = parts.allSatisfy { ($0["type"] as? String) == "text" }
            if onlyText {
                result.append(["role": "user", "content": parts.compactMap { $0["text"] as? String }.joined(separator: "\n")])
            } else {
                result.append(["role": "user", "content": parts])
            }
        }
        return result
    }

    /// tool_result 的 content(字符串或块数组)转文本;图片以占位符表示。
    static func toolResultText(_ value: Any?, isError: Bool) -> String {
        var text = ""
        if let string = value as? String {
            text = string
        } else if let blocks = value as? [[String: Any]] {
            text = blocks.compactMap { block -> String? in
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return isError ? "Error: \(text)" : text
    }

    /// Anthropic 图片来源 → data URL / 远程地址。
    static func imageURL(_ source: Any?) -> String? {
        guard let source = source as? [String: Any] else { return nil }
        switch source["type"] as? String {
        case "base64":
            guard let data = source["data"] as? String, let media = source["media_type"] as? String else { return nil }
            return "data:\(media);base64,\(data)"
        case "url": return source["url"] as? String
        default: return nil
        }
    }

    /// Anthropic 工具定义 → OpenAI function 工具;服务端内置工具(带非 custom 的 type)被丢弃。
    static func toolDefinition(_ tool: [String: Any]) -> [String: Any]? {
        if let type = tool["type"] as? String, type != "custom" { return nil }
        guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
        var function: [String: Any] = ["name": name, "parameters": tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()]]
        if let description = tool["description"] as? String { function["description"] = description }
        return ["type": "function", "function": function]
    }

    /// tool_choice 映射。
    static func toolChoice(_ value: Any?) -> Any? {
        guard let choice = value as? [String: Any], let type = choice["type"] as? String else { return nil }
        switch type {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            guard let name = choice["name"] as? String else { return nil }
            return ["type": "function", "function": ["name": name]]
        default: return nil
        }
    }

    // MARK: - 响应方向

    /// OpenAI finish_reason → Anthropic stop_reason。
    public static func stopReason(fromFinish reason: String?, hadToolCalls: Bool) -> String {
        switch reason {
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        default: return hadToolCalls ? "tool_use" : "end_turn"
        }
    }

    /// 把 OpenAI 非流式响应转换为 Anthropic Message。
    /// - Parameters:
    ///   - data: OpenAI 响应 JSON
    ///   - model: 回填的模型名(上游缺失时使用)
    /// - Returns: Anthropic 响应 JSON
    /// - Throws: `ProxyMappingError.invalidResponse`
    public static func anthropicResponse(fromOpenAI data: Data, model: String) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw ProxyMappingError.invalidResponse }
        var content: [[String: Any]] = []
        if let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String), !reasoning.isEmpty {
            content.append(["type": "thinking", "thinking": reasoning, "signature": ""])
        }
        if let text = message["content"] as? String, !text.isEmpty { content.append(["type": "text", "text": text]) }
        var hadTools = false
        for call in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let function = call["function"] as? [String: Any] else { continue }
            hadTools = true
            let arguments = (function["arguments"] as? String) ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
            content.append([
                "type": "tool_use",
                "id": (call["id"] as? String) ?? "toolu_\(UUID().uuidString.prefix(12))",
                "name": (function["name"] as? String) ?? "",
                "input": input,
            ])
        }
        let usage = anthropicUsage(root["usage"] as? [String: Any])
        let out: [String: Any] = [
            "id": (root["id"] as? String) ?? "msg_\(UUID().uuidString.prefix(12))",
            "type": "message",
            "role": "assistant",
            "model": (root["model"] as? String) ?? model,
            "content": content,
            "stop_reason": stopReason(fromFinish: choice["finish_reason"] as? String, hadToolCalls: hadTools),
            "stop_sequence": NSNull(),
            "usage": usage,
        ]
        return try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// OpenAI usage → Anthropic usage(缓存命中的 token 单独计)。
    static func anthropicUsage(_ usage: [String: Any]?) -> [String: Any] {
        let prompt = (usage?["prompt_tokens"] as? Int) ?? 0
        let completion = (usage?["completion_tokens"] as? Int) ?? 0
        let cached = ((usage?["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
        var result: [String: Any] = ["input_tokens": max(prompt - cached, 0), "output_tokens": completion]
        if cached > 0 { result["cache_read_input_tokens"] = cached }
        return result
    }

    /// 构造 Anthropic 错误体。
    /// - Parameters:
    ///   - status: 上游 HTTP 状态码
    ///   - message: 错误说明(调用方保证不含密钥)
    /// - Returns: `{"type":"error","error":{…}}`
    public static func anthropicError(status: Int, message: String) -> Data {
        let type: String
        switch status {
        case 400, 422: type = "invalid_request_error"
        case 401: type = "authentication_error"
        case 403: type = "permission_error"
        case 404: type = "not_found_error"
        case 429: type = "rate_limit_error"
        case 529: type = "overloaded_error"
        default: type = "api_error"
        }
        let object: [String: Any] = ["type": "error", "error": ["type": type, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// 从上游错误响应体里提取可读信息(`error.message` 或原文前 300 字)。
    /// - Parameter body: 上游响应体
    /// - Returns: 说明文字
    public static func upstreamMessage(from body: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
        }
        return String(String(data: body, encoding: .utf8)?.prefix(300) ?? "")
    }
}
