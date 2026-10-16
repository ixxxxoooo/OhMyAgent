// @author ixxxxoooo
// 模型别名路由、Anthropic 透传、model 改写与 SSE 分行测试(本地桩上游,不依赖网络)。

import Foundation
import Testing
@testable import ProviderProxyKit

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HTTPRequest] = []
    func add(_ request: HTTPRequest) { lock.withLock { items.append(request) } }
    var all: [HTTPRequest] { lock.withLock { items } }
}

private func startStub(_ seen: Seen, _ respond: @escaping @Sendable (HTTPRequest) -> HTTPResult) async throws -> (LoopbackHTTPServer, URL) {
    let server = LoopbackHTTPServer { request in
        seen.add(request)
        return respond(request)
    }
    let port = try await server.start()
    guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw LoopbackServerError.listenerFailed("url") }
    return (server, url)
}

private func send(_ base: URL, _ body: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: base.appendingPathComponent("v1/messages"))
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
}

@Suite("model 字段改写")
struct ModelRewriterTests {
    @Test("紧凑与带空格的写法都能读到并替换,其余字节保持不变")
    func rewriteInPlace() {
        let compact = Data(#"{"model":"oma-main","max_tokens":8,"messages":[{"role":"user","content":"hi \"model\":\"x\""}]}"#.utf8)
        #expect(ModelRewriter.peekModel(compact) == "oma-main")
        let out = String(decoding: ModelRewriter.rewrite(compact, to: "deepseek-chat"), as: UTF8.self)
        #expect(out.hasPrefix(#"{"model":"deepseek-chat","max_tokens":8"#))
        #expect(out.hasSuffix(#"hi \"model\":\"x\""}]}"#), "正文里被转义的 model 字样不受影响")

        let spaced = Data(#"{ "model" : "a\"b", "x": 1 }"#.utf8)
        #expect(ModelRewriter.peekModel(spaced) == #"a\"b"#)
        #expect(String(decoding: ModelRewriter.rewrite(spaced, to: "m"), as: UTF8.self) == #"{ "model" : "m", "x": 1 }"#)
    }

    @Test("model 不在开头窗口内时回退完整 JSON 解析;模型名里的引号被转义")
    func fallback() throws {
        let padding = String(repeating: "a", count: 700)
        let body = Data(#"{"system":"\#(padding)","model":"oma-main"}"#.utf8)
        #expect(ModelRewriter.locate(body) == nil)
        #expect(ModelRewriter.peekModel(body) == "oma-main")
        let rewrittenData = ModelRewriter.rewrite(body, to: "x")
        let rewritten = try #require(try JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any])
        #expect(rewritten["model"] as? String == "x")

        let quoted = ModelRewriter.rewrite(Data(#"{"model":"a"}"#.utf8), to: #"we"ird"#)
        let object = try #require(try JSONSerialization.jsonObject(with: quoted) as? [String: Any])
        #expect(object["model"] as? String == #"we"ird"#)
    }

    @Test("工具 schema 里名为 model 的属性不会被误认为顶层字段")
    func nestedModelKey() {
        let body = Data(#"{"max_tokens":1,"tools":[{"input_schema":{"properties":{"model":{"type":"string"}}}}],"model":"top"}"#.utf8)
        #expect(ModelRewriter.peekModel(body) == "top")
    }
}

@Suite("SSE 分行")
struct LineSplitterTests {
    @Test("跨块拆分、CRLF 与残留行")
    func splitting() {
        var splitter = LineSplitter()
        #expect(splitter.push(Data("data: {\"a\"".utf8)).isEmpty)
        #expect(splitter.push(Data(":1}\r\n\r\nevent: x\n".utf8)) == ["data: {\"a\":1}", "", "event: x"])
        #expect(splitter.push(Data("tail".utf8)).isEmpty)
        #expect(splitter.flush() == "tail")
        #expect(splitter.flush() == nil)
    }
}

@Suite("别名路由与透传")
struct AliasRoutingTests {
    @Test("Anthropic 协议透传:改写 model、x-api-key 鉴权、转发 beta 头、SSE 字节原样返回")
    func passthroughStreaming() async throws {
        let seen = Seen()
        let sse = "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let (upstream, base) = try await startStub(seen) { _ in
            .stream(status: 200, headers: ["Content-Type": "text/event-stream"], body: AsyncStream { continuation in
                continuation.yield(Data(sse.prefix(40).utf8))
                continuation.yield(Data(sse.dropFirst(40).utf8))
                continuation.finish()
            })
        }
        defer { upstream.stop() }
        let proxy = ProviderProxy(gateway: LocalGateway())
        let target = ProxyTarget(wire: .anthropic,
                                 route: ProxyRoute(upstreamBase: base.appendingPathComponent("anthropic"), apiKey: "sk-secret", extraHeaders: ["x-extra": "1"], usesAPIKeyHeader: true),
                                 model: "real-model", label: "t")
        let url = try await proxy.register(key: "s", targets: ["oma-main": target], fallback: target)
        let (data, http) = try await send(url, #"{"model":"oma-main","stream":true,"messages":[{"role":"user","content":"hi"}]}"#, headers: ["anthropic-beta": "b1", "anthropic-version": "2023-06-01"])
        #expect(http.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == sse)
        let request = try #require(seen.all.first)
        #expect(request.path == "/anthropic/v1/messages")
        #expect(request.headers["x-api-key"] == "sk-secret")
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["anthropic-beta"] == "b1")
        #expect(request.headers["x-extra"] == "1")
        #expect(ModelRewriter.peekModel(request.body) == "real-model")
        await proxy.shutdown()
    }

    @Test("Bearer 鉴权与上游 4xx:状态码透传并改写为 Anthropic 错误体;Cloudflare 1010 给出提示")
    func passthroughErrors() async throws {
        let seen = Seen()
        let (upstream, base) = try await startStub(seen) { request in
            if String(decoding: request.body, as: UTF8.self).contains("blocked") { return .full(status: 403, headers: [:], body: Data("error code: 1010".utf8)) }
            return .full(status: 429, headers: [:], body: Data(#"{"error":{"message":"额度不足"}}"#.utf8))
        }
        defer { upstream.stop() }
        let proxy = ProviderProxy(gateway: LocalGateway())
        let target = ProxyTarget(wire: .anthropic, route: ProxyRoute(upstreamBase: base, apiKey: "k"), model: "blocked", label: "t")
        let url = try await proxy.register(key: "s", targets: [:], fallback: target)
        let (cloud, cloudHTTP) = try await send(url, #"{"model":"x","messages":[]}"#)
        #expect(cloudHTTP.statusCode == 403)
        #expect(String(decoding: cloud, as: UTF8.self).contains("1010"))
        #expect(seen.all.first?.headers["authorization"] == "Bearer k")

        var limited = target
        limited.model = "ok"
        let again = try await proxy.register(key: "s2", targets: [:], fallback: limited)
        let (body, http) = try await send(again, #"{"model":"x","messages":[]}"#)
        #expect(http.statusCode == 429)
        #expect(String(decoding: body, as: UTF8.self).contains("额度不足"))
        await proxy.shutdown()
    }

    @Test("同一路由按别名分发到不同协议与厂商,未知模型走兜底目标")
    func aliasDispatch() async throws {
        let anthropicSeen = Seen()
        let openAISeen = Seen()
        let (anthropic, anthropicBase) = try await startStub(anthropicSeen) { _ in
            .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"type":"message","content":[{"type":"text","text":"from-anthropic"}]}"#.utf8))
        }
        let (openAI, openAIBase) = try await startStub(openAISeen) { _ in
            .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"id":"c","choices":[{"message":{"content":"from-openai"},"finish_reason":"stop"}],"usage":{}}"#.utf8))
        }
        defer { anthropic.stop(); openAI.stop() }
        let proxy = ProviderProxy(gateway: LocalGateway())
        let a = ProxyTarget(wire: .anthropic, route: ProxyRoute(upstreamBase: anthropicBase, apiKey: "ka"), model: "claude-x", label: "a")
        let o = ProxyTarget(wire: .openAI, route: ProxyRoute(upstreamBase: openAIBase.appendingPathComponent("v1"), apiKey: "ko"), model: "gpt-x", label: "o")
        let url = try await proxy.register(key: "s", targets: ["oma-main": a, "oma-fast": o], fallback: a)

        let (first, _) = try await send(url, #"{"model":"oma-main","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(String(decoding: first, as: UTF8.self).contains("from-anthropic"))
        let (second, _) = try await send(url, #"{"model":"oma-fast","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(String(decoding: second, as: UTF8.self).contains("from-openai"))
        let (third, _) = try await send(url, #"{"model":"claude-haiku-whatever","messages":[{"role":"user","content":"hi"}]}"#)
        #expect(String(decoding: third, as: UTF8.self).contains("from-anthropic"), "未知别名走兜底")

        #expect(anthropicSeen.all.count == 2)
        #expect(openAISeen.all.count == 1)
        let openAIRequest = try #require(openAISeen.all.first)
        let openAIBody = try #require(try JSONSerialization.jsonObject(with: openAIRequest.body) as? [String: Any])
        #expect(openAIBody["model"] as? String == "gpt-x", "OpenAI 上游收到的是真实模型名而不是别名")
        await proxy.shutdown()
    }

    @Test("注销路由后返回 404;密钥不会出现在响应里")
    func unregister() async throws {
        let seen = Seen()
        let (upstream, base) = try await startStub(seen) { _ in .full(status: 200, headers: [:], body: Data("{}".utf8)) }
        defer { upstream.stop() }
        let proxy = ProviderProxy(gateway: LocalGateway())
        let target = ProxyTarget(wire: .anthropic, route: ProxyRoute(upstreamBase: base, apiKey: "sk-super-secret"), label: "t")
        let url = try await proxy.register(key: "s", targets: [:], fallback: target)
        let (data, http) = try await send(url, #"{"model":"m","messages":[]}"#)
        #expect(http.statusCode == 200)
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-super-secret"))
        await proxy.unregister(key: "s")
        let (_, gone) = try await send(url, #"{"model":"m","messages":[]}"#)
        #expect(gone.statusCode == 404)
        await proxy.shutdown()
    }
}
