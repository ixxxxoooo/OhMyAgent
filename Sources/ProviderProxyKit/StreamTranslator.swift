// @author ixxxxoooo
// OpenAI Chat Completions 流式分块 → Anthropic Messages SSE 事件的状态机(纯逻辑,无网络)。
//
// 事件顺序:message_start → (content_block_start → delta* → content_block_stop)* → message_delta → message_stop。
// 同一时刻最多打开一个内容块;文本、思考、工具调用互相切换时先关闭上一个块。

import Foundation

/// 流式翻译器(值类型,逐行喂入上游 `data:` 内容)。
public struct StreamTranslator: Sendable {
    /// 当前打开的块。
    private enum Open: Equatable {
        case none
        case text(Int)
        case thinking(Int)
        case tool(Int)
    }

    private let model: String
    private var started = false
    private var finished = false
    private var open = Open.none
    private var nextIndex = 0
    /// OpenAI tool_calls 的 index → Anthropic 块序号
    private var toolBlocks: [Int: Int] = [:]
    /// OpenAI tool_calls 的 index → 该调用的 id(部分厂商所有调用都用 index 0,靠 id 区分)
    private var toolIds: [Int: String] = [:]
    private var finishReason: String?
    private var hadToolCalls = false
    private var inputTokens = 0
    private var outputTokens = 0
    private var cachedTokens = 0
    private var messageId = "msg_\(UUID().uuidString.prefix(12))"

    /// 创建翻译器。
    /// - Parameter model: 请求的模型名(上游分块缺失 model 字段时回填)
    public init(model: String) { self.model = model }

    /// 是否已结束(已发出 message_stop 或错误事件)。
    public var isFinished: Bool { finished }

    /// 处理上游的一条 `data:` 负载。
    /// - Parameter payload: 去掉 `data:` 前缀并裁剪空白后的内容(可为 `[DONE]`)
    /// - Returns: 需要写给客户端的 SSE 文本片段(可能为空)
    public mutating func consume(payload: String) -> [String] {
        if finished { return [] }
        if payload == "[DONE]" { return finish() }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
        var out: [String] = []
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "upstream error"
            return failEvent(message: message)
        }
        if !started { out += start(id: root["id"] as? String, model: root["model"] as? String) }
        if let usage = root["usage"] as? [String: Any] {
            inputTokens = (usage["prompt_tokens"] as? Int) ?? inputTokens
            outputTokens = (usage["completion_tokens"] as? Int) ?? outputTokens
            cachedTokens = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? cachedTokens
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return out }
        if let delta = choice["delta"] as? [String: Any] {
            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                out += appendThinking(reasoning)
            }
            if let text = delta["content"] as? String, !text.isEmpty { out += appendText(text) }
            for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] { out += appendToolCall(call) }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        return out
    }

    /// 上游流结束(`[DONE]` 或连接关闭)时调用:关闭块并发出收尾事件。
    /// - Returns: SSE 文本片段;已结束时为空
    public mutating func finish() -> [String] {
        if finished { return [] }
        var out: [String] = []
        if !started { out += start(id: nil, model: nil) }
        out += closeOpen()
        let reason = ProtocolMapping.stopReason(fromFinish: finishReason, hadToolCalls: hadToolCalls)
        var usage: [String: Any] = ["input_tokens": max(inputTokens - cachedTokens, 0), "output_tokens": outputTokens]
        if cachedTokens > 0 { usage["cache_read_input_tokens"] = cachedTokens }
        out.append(Self.event("message_delta", ["type": "message_delta", "delta": ["stop_reason": reason, "stop_sequence": NSNull()], "usage": usage]))
        out.append(Self.event("message_stop", ["type": "message_stop"]))
        finished = true
        return out
    }

    /// 上游在流中途失败时,向客户端发出 error 事件并结束。
    /// - Parameter message: 错误说明(不含密钥)
    /// - Returns: SSE 文本片段
    public mutating func failEvent(message: String) -> [String] {
        if finished { return [] }
        finished = true
        let object: [String: Any] = ["type": "error", "error": ["type": "api_error", "message": message]]
        return [Self.event("error", object)]
    }

    // MARK: - 内部

    private mutating func start(id: String?, model upstreamModel: String?) -> [String] {
        started = true
        if let id, !id.isEmpty { messageId = id.hasPrefix("msg_") ? id : "msg_\(id)" }
        let message: [String: Any] = [
            "id": messageId, "type": "message", "role": "assistant",
            "model": upstreamModel ?? model, "content": [Any](), "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": 0],
        ]
        return [Self.event("message_start", ["type": "message_start", "message": message])]
    }

    private mutating func appendText(_ text: String) -> [String] {
        var out: [String] = []
        if case .text(let index) = open {
            out.append(Self.delta(index, ["type": "text_delta", "text": text]))
            return out
        }
        out += closeOpen()
        let index = nextIndex
        nextIndex += 1
        open = .text(index)
        out.append(Self.event("content_block_start", ["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]]))
        out.append(Self.delta(index, ["type": "text_delta", "text": text]))
        return out
    }

    private mutating func appendThinking(_ text: String) -> [String] {
        var out: [String] = []
        if case .thinking(let index) = open {
            out.append(Self.delta(index, ["type": "thinking_delta", "thinking": text]))
            return out
        }
        out += closeOpen()
        let index = nextIndex
        nextIndex += 1
        open = .thinking(index)
        out.append(Self.event("content_block_start", ["type": "content_block_start", "index": index, "content_block": ["type": "thinking", "thinking": ""]]))
        out.append(Self.delta(index, ["type": "thinking_delta", "thinking": text]))
        return out
    }

    private mutating func appendToolCall(_ call: [String: Any]) -> [String] {
        let openAIIndex = (call["index"] as? Int) ?? 0
        let function = call["function"] as? [String: Any]
        let arguments = (function?["arguments"] as? String) ?? ""
        var out: [String] = []
        let callId = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let blockIndex = toolBlocks[openAIIndex], callId == nil || callId == toolIds[openAIIndex] {
            if !arguments.isEmpty { out.append(Self.delta(blockIndex, ["type": "input_json_delta", "partial_json": arguments])) }
            return out
        }
        // 新的工具调用:关闭当前块并开启 tool_use 块
        out += closeOpen()
        let index = nextIndex
        nextIndex += 1
        toolBlocks[openAIIndex] = index
        open = .tool(index)
        hadToolCalls = true
        let id = callId ?? "toolu_\(UUID().uuidString.prefix(12))"
        toolIds[openAIIndex] = id
        let name = (function?["name"] as? String) ?? ""
        out.append(Self.event("content_block_start", ["type": "content_block_start", "index": index, "content_block": ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()]]))
        if !arguments.isEmpty { out.append(Self.delta(index, ["type": "input_json_delta", "partial_json": arguments])) }
        return out
    }

    private mutating func closeOpen() -> [String] {
        var out: [String] = []
        switch open {
        case .none: return []
        case .thinking(let index):
            out.append(Self.delta(index, ["type": "signature_delta", "signature": ""]))
            out.append(Self.event("content_block_stop", ["type": "content_block_stop", "index": index]))
        case .text(let index), .tool(let index):
            out.append(Self.event("content_block_stop", ["type": "content_block_stop", "index": index]))
        }
        open = .none
        return out
    }

    private static func delta(_ index: Int, _ delta: [String: Any]) -> String {
        event("content_block_delta", ["type": "content_block_delta", "index": index, "delta": delta])
    }

    /// 序列化为一条 SSE 事件。
    static func event(_ name: String, _ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return "event: \(name)\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
    }
}
