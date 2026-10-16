// @author ixxxxoooo
// 协议映射与流式翻译测试。

import Foundation
import Testing
@testable import ProviderProxyKit

private func object(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

@Suite("Anthropic → OpenAI 请求映射")
struct RequestMappingTests {
    @Test("system、文本、参数与流式选项")
    func basics() throws {
        let body = #"{"model":"gpt-4o","max_tokens":128,"system":[{"type":"text","text":"你是助手"},{"type":"text","text":"简短回答"}],"temperature":0.5,"stop_sequences":["END"],"stream":true,"messages":[{"role":"user","content":"你好"}]}"#
        let mapped = try ProtocolMapping.openAIRequest(fromAnthropic: Data(body.utf8))
        let out = object(mapped.body)
        #expect(mapped.stream)
        #expect(mapped.model == "gpt-4o")
        #expect(out["max_tokens"] as? Int == 128)
        #expect(out["stop"] as? [String] == ["END"])
        #expect((out["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        let messages = out["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "你是助手\n\n简短回答")
        #expect(messages[1]["content"] as? String == "你好")
    }

    @Test("工具调用往返:assistant.tool_use → tool_calls,user.tool_result → tool 消息在前")
    func toolRoundTrip() throws {
        let body = """
        {"model":"m","messages":[
          {"role":"user","content":"读文件"},
          {"role":"assistant","content":[{"type":"text","text":"好的"},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"path":"a.txt"}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"内容"}]},{"type":"text","text":"继续"}]}
        ],"tools":[{"name":"Read","description":"读","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}},{"type":"web_search_20250305","name":"web_search"}],"tool_choice":{"type":"any"}}
        """
        let out = object(try ProtocolMapping.openAIRequest(fromAnthropic: Data(body.utf8)).body)
        let messages = out["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 4)
        let calls = messages[1]["tool_calls"] as? [[String: Any]] ?? []
        #expect(calls.first?["id"] as? String == "toolu_1")
        #expect((calls.first?["function"] as? [String: Any])?["arguments"] as? String == #"{"path":"a.txt"}"#)
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[2]["tool_call_id"] as? String == "toolu_1")
        #expect(messages[2]["content"] as? String == "内容")
        #expect(messages[3]["role"] as? String == "user")
        let tools = out["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == 1, "服务端内置工具应被丢弃")
        #expect(out["tool_choice"] as? String == "required")
    }

    @Test("图片转 data URL,错误结果带前缀")
    func imageAndError() throws {
        let body = #"{"model":"m","messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"看图"}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","is_error":true,"content":"boom"}]}]}"#
        let messages = object(try ProtocolMapping.openAIRequest(fromAnthropic: Data(body.utf8)).body)["messages"] as? [[String: Any]] ?? []
        let parts = messages[0]["content"] as? [[String: Any]] ?? []
        #expect((parts.first?["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AAAA")
        #expect(messages[1]["content"] as? String == "Error: boom")
    }

    @Test("非法请求抛错;只有思考块的 assistant 消息被丢弃")
    func invalid() throws {
        #expect(throws: ProxyMappingError.invalidRequest) { try ProtocolMapping.openAIRequest(fromAnthropic: Data("nope".utf8)) }
        let body = #"{"model":"m","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"x","signature":"s"}]},{"role":"user","content":"hi"}]}"#
        let messages = object(try ProtocolMapping.openAIRequest(fromAnthropic: Data(body.utf8)).body)["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 1)
    }
}

@Suite("OpenAI → Anthropic 响应映射")
struct ResponseMappingTests {
    @Test("文本与工具调用、stop_reason、缓存 usage")
    func response() throws {
        let body = #"{"id":"chatcmpl-1","model":"gpt-4o","choices":[{"message":{"content":"好","tool_calls":[{"id":"call_1","function":{"name":"Read","arguments":"{\"path\":\"a\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}"#
        let out = object(try ProtocolMapping.anthropicResponse(fromOpenAI: Data(body.utf8), model: "m"))
        #expect(out["stop_reason"] as? String == "tool_use")
        let content = out["content"] as? [[String: Any]] ?? []
        #expect(content.count == 2)
        #expect(content[1]["type"] as? String == "tool_use")
        #expect((content[1]["input"] as? [String: Any])?["path"] as? String == "a")
        let usage = out["usage"] as? [String: Any] ?? [:]
        #expect(usage["input_tokens"] as? Int == 6)
        #expect(usage["cache_read_input_tokens"] as? Int == 4)
    }

    @Test("stop_reason 映射与错误体")
    func reasons() {
        #expect(ProtocolMapping.stopReason(fromFinish: "length", hadToolCalls: false) == "max_tokens")
        #expect(ProtocolMapping.stopReason(fromFinish: "stop", hadToolCalls: true) == "tool_use")
        #expect(ProtocolMapping.stopReason(fromFinish: "stop", hadToolCalls: false) == "end_turn")
        let error = object(ProtocolMapping.anthropicError(status: 429, message: "slow"))
        #expect((error["error"] as? [String: Any])?["type"] as? String == "rate_limit_error")
        #expect(ProtocolMapping.upstreamMessage(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)) == "bad key")
    }
}

@Suite("流式翻译")
struct StreamTranslatorTests {
    private func events(_ pieces: [String]) -> [String] {
        pieces.compactMap { $0.split(separator: "\n").first.map { String($0.dropFirst("event: ".count)) } }
    }

    @Test("纯文本流:start → text → stop,usage 在 finish 之后到达也能带上")
    func text() {
        var t = StreamTranslator(model: "m")
        var out: [String] = []
        out += t.consume(payload: #"{"id":"c1","choices":[{"delta":{"role":"assistant","content":"你"}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"content":"好"}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        out += t.consume(payload: #"{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#)
        out += t.consume(payload: "[DONE]")
        #expect(events(out) == ["message_start", "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop", "message_delta", "message_stop"])
        #expect(out.joined().contains(#""output_tokens":2"#))
        #expect(out.joined().contains(#""stop_reason":"end_turn""#))
        #expect(t.finish().isEmpty, "重复结束不应再发事件")
    }

    @Test("工具调用分片:参数增量拼接,stop_reason 为 tool_use")
    func tools() {
        var t = StreamTranslator(model: "m")
        var out: [String] = []
        out += t.consume(payload: #"{"choices":[{"delta":{"content":"先读"}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"Read","arguments":""}}]}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"p\":"}}]}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"Glob","arguments":"{}"}}]}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        out += t.finish()
        let text = out.joined()
        #expect(text.contains(#""name":"Read""#))
        #expect(text.contains(#""partial_json":"{\"p\":""#))
        #expect(text.contains(#""name":"Glob""#))
        #expect(text.contains(#""stop_reason":"tool_use""#))
        #expect(events(out).filter { $0 == "content_block_stop" }.count == 3)
    }

    @Test("同为 index 0 但 id 不同视为新的工具调用;思考内容先于文本")
    func sameIndexAndThinking() {
        var t = StreamTranslator(model: "m")
        var out: [String] = []
        out += t.consume(payload: #"{"choices":[{"delta":{"reasoning_content":"想"}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"content":"答"}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"A","arguments":"{}"}}]}}]}"#)
        out += t.consume(payload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"b","function":{"name":"B","arguments":"{}"}}]}}]}"#)
        out += t.finish()
        let text = out.joined()
        #expect(text.contains(#""type":"thinking""#))
        #expect(text.contains("signature_delta"))
        #expect(text.contains(#""name":"A""#) && text.contains(#""name":"B""#))
    }

    @Test("上游错误分块转为 error 事件并终止")
    func errorChunk() {
        var t = StreamTranslator(model: "m")
        let out = t.consume(payload: #"{"error":{"message":"quota"}}"#)
        #expect(events(out) == ["error"])
        #expect(t.isFinished)
        #expect(t.consume(payload: "[DONE]").isEmpty)
    }
}
