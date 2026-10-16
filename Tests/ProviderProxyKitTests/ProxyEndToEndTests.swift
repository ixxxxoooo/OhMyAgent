// @author ixxxxoooo
// 代理端到端测试:本地桩上游 + 真实回环代理 + URLSession 客户端(不依赖网络与真实模型)。

import Foundation
import Testing
@testable import ProviderProxyKit

/// 记录上游收到的请求。
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    func add(_ request: HTTPRequest) { lock.withLock { requests.append(request) } }
    var all: [HTTPRequest] { lock.withLock { requests } }
}

private func startUpstream(_ capture: Capture, _ respond: @escaping @Sendable (HTTPRequest) -> HTTPResult) async throws -> (LoopbackHTTPServer, URL) {
    let server = LoopbackHTTPServer { request in
        capture.add(request)
        return respond(request)
    }
    let port = try await server.start()
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1") else { throw LoopbackServerError.listenerFailed("url") }
    return (server, url)
}

private func post(_ base: URL, path: String = "v1/messages", body: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
}

@Suite("协议代理端到端")
struct ProxyEndToEndTests {
    @Test("非流式:转换请求、带上密钥与附加头,回译响应")
    func nonStreaming() async throws {
        let capture = Capture()
        let reply = #"{"id":"c1","model":"up","choices":[{"message":{"content":"你好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#
        let (upstream, upstreamURL) = try await startUpstream(capture) { _ in .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(reply.utf8)) }
        defer { upstream.stop() }
        let proxy = ProviderProxy()
        let base = try await proxy.register(key: "t", route: ProxyRoute(upstreamBase: upstreamURL, apiKey: "sk-test-secret", extraHeaders: ["x-opencode-client": "cli"]))
        let (data, http) = try await post(base, body: #"{"model":"gpt","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(http.statusCode == 200)
        let out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        #expect(out["type"] as? String == "message")
        #expect((out["content"] as? [[String: Any]])?.first?["text"] as? String == "你好")
        let seen = try #require(capture.all.first)
        #expect(seen.path == "/v1/chat/completions")
        #expect(seen.headers["authorization"] == "Bearer sk-test-secret")
        #expect(seen.headers["x-opencode-client"] == "cli")
        await proxy.shutdown()
    }

    @Test("流式:SSE 逐块翻译为 Anthropic 事件")
    func streaming() async throws {
        let capture = Capture()
        let sse = """
        data: {"id":"c1","choices":[{"delta":{"content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}

        data: [DONE]


        """
        let (upstream, upstreamURL) = try await startUpstream(capture) { _ in
            let stream = AsyncStream<Data> { continuation in
                continuation.yield(Data(sse.utf8))
                continuation.finish()
            }
            return .stream(status: 200, headers: ["Content-Type": "text/event-stream"], body: stream)
        }
        defer { upstream.stop() }
        let proxy = ProviderProxy()
        let base = try await proxy.register(key: "t", route: ProxyRoute(upstreamBase: upstreamURL, apiKey: ""))
        let (data, http) = try await post(base, body: #"{"model":"gpt","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(http.statusCode == 200)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("event: message_start"))
        #expect(text.contains(#""text":"你""#) && text.contains(#""text":"好""#))
        #expect(text.contains("event: message_stop"))
        let seen = try #require(capture.all.first)
        #expect(seen.headers["authorization"] == nil, "无密钥时不带 Authorization")
        await proxy.shutdown()
    }

    @Test("上游错误码透传并改写为 Anthropic 错误体;免费层拒绝给出提示")
    func upstreamErrors() async throws {
        let capture = Capture()
        let (upstream, upstreamURL) = try await startUpstream(capture) { request in
            let body = String(decoding: request.body, as: UTF8.self)
            if body.contains("free-model") { return .full(status: 401, headers: [:], body: Data(#"{"type":"error","error":{"type":"FreeTierError","message":"x"}}"#.utf8)) }
            return .full(status: 429, headers: [:], body: Data(#"{"error":{"message":"额度不足"}}"#.utf8))
        }
        defer { upstream.stop() }
        let proxy = ProviderProxy()
        let base = try await proxy.register(key: "t", route: ProxyRoute(upstreamBase: upstreamURL, apiKey: "k"))
        let (limited, http) = try await post(base, body: #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(http.statusCode == 429)
        #expect(String(decoding: limited, as: UTF8.self).contains("额度不足"))
        let (free, freeHTTP) = try await post(base, body: #"{"model":"free-model","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(freeHTTP.statusCode == 401)
        #expect(String(decoding: free, as: UTF8.self).contains("OpenCode"))
        await proxy.shutdown()
    }

    @Test("未知令牌返回 404;同一路由键重复注册沿用同一地址")
    func routing() async throws {
        let proxy = ProviderProxy()
        let route = ProxyRoute(upstreamBase: try #require(URL(string: "http://127.0.0.1:1/v1")), apiKey: "")
        let first = try await proxy.register(key: "a", route: route)
        let again = try await proxy.register(key: "a", route: route)
        #expect(first == again)
        let other = try await proxy.register(key: "b", route: route)
        #expect(other != first)
        var wrong = first.deletingLastPathComponent()
        wrong.append(path: "deadbeef")
        let (_, http) = try await post(wrong, body: "{}")
        #expect(http.statusCode == 404)
        let (counted, countHTTP) = try await post(first, path: "v1/messages/count_tokens", body: #"{"messages":[]}"#)
        #expect(countHTTP.statusCode == 200 && String(decoding: counted, as: UTF8.self).contains("input_tokens"))
        await proxy.shutdown()
    }
}
