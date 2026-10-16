// @author ixxxxoooo
// 协议转换代理:Claude Code 只会说 Anthropic Messages 协议,OpenAI 协议的厂商经本代理接入。
//
// 流程:Claude Code → `http://127.0.0.1:端口/<令牌>/v1/messages` → 本代理转换 → 厂商 `/chat/completions`。
// 真实的上游地址与密钥只保存在本进程内存里(不进入 Claude Code 子进程的环境变量);
// 路径里的随机令牌用来区分路由,也避免本机其他进程随意借用密钥。
// 日志只记录路由标识、状态码与耗时,不记录请求/响应正文与任何密钥。

import Foundation
import OMLog

/// 一条代理路由(上游信息)。
public struct ProxyRoute: Sendable {
    /// 上游基础地址(含版本前缀,如 `https://api.openai.com/v1`)
    public var upstreamBase: URL
    /// 上游密钥(可为空:本地模型无需密钥)
    public var apiKey: String
    /// 附加请求头(如 OpenCode 兼容头)
    public var extraHeaders: [String: String]

    public init(upstreamBase: URL, apiKey: String, extraHeaders: [String: String] = [:]) {
        self.upstreamBase = upstreamBase
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
    }
}

/// 协议转换代理(应用内共享一个实例,首次注册路由时才启动监听)。
public actor ProviderProxy {
    /// 应用共享实例。
    public static let shared = ProviderProxy()

    private var server: LoopbackHTTPServer?
    private var port: UInt16?
    /// 路由键(如提供商 ID)→ 令牌
    private var tokens: [String: String] = [:]
    /// 令牌 → 路由
    private var routes: [String: (key: String, route: ProxyRoute)] = [:]
    private let session: URLSession

    /// 创建代理。
    /// - Parameter session: 上游请求使用的会话(测试可注入)
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            configuration.waitsForConnectivity = false
            return configuration
        }())
    }

    /// 注册(或更新)一条路由,必要时启动监听。
    /// - Parameters:
    ///   - key: 路由键(同一键重复注册沿用同一令牌,已建立的会话不会失效)
    ///   - route: 上游信息
    /// - Returns: 交给 Claude Code 作为 `ANTHROPIC_BASE_URL` 的本地地址
    /// - Throws: 监听启动失败
    public func register(key: String, route: ProxyRoute) async throws -> URL {
        let port = try await ensureStarted()
        let token = tokens[key] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens[key] = token
        routes[token] = (key, route)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)") else { throw LoopbackServerError.listenerFailed("bad url") }
        return url
    }

    /// 停止监听并清空路由。
    public func shutdown() {
        server?.stop()
        server = nil
        port = nil
        tokens.removeAll()
        routes.removeAll()
    }

    private func ensureStarted() async throws -> UInt16 {
        if let port { return port }
        let server = LoopbackHTTPServer { [weak self] request in
            guard let self else { return Self.error(status: 503, message: "proxy stopped") }
            return await self.handle(request)
        }
        let port = try await server.start()
        self.server = server
        self.port = port
        Log.agent.info("协议代理已启动", ["port": "\(port)"])
        return port
    }

    // MARK: - 请求处理

    private func handle(_ request: HTTPRequest) async -> HTTPResult {
        // 路径形如 /<令牌>/v1/messages
        let parts = request.path.split(separator: "?", maxSplits: 1).first.map(String.init)?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) ?? []
        guard parts.count >= 2, let entry = routes[parts[0]] else { return Self.error(status: 404, message: "unknown route") }
        let tail = "/" + parts.dropFirst().joined(separator: "/")
        switch (request.method.uppercased(), tail) {
        case ("POST", "/v1/messages"):
            return await forward(request, key: entry.key, route: entry.route)
        case ("POST", "/v1/messages/count_tokens"):
            return Self.countTokens(request.body)
        case ("GET", "/v1/models"):
            return .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"data":[],"has_more":false}"#.utf8))
        default:
            return Self.error(status: 404, message: "unsupported endpoint")
        }
    }

    private func forward(_ request: HTTPRequest, key: String, route: ProxyRoute) async -> HTTPResult {
        let started = ContinuousClock.now
        let mapped: MappedRequest
        do { mapped = try ProtocolMapping.openAIRequest(fromAnthropic: request.body) } catch {
            return Self.error(status: 400, message: "invalid request body")
        }
        var upstream = URLRequest(url: Self.chatURL(route.upstreamBase), cachePolicy: .reloadIgnoringLocalCacheData)
        upstream.httpMethod = "POST"
        upstream.httpBody = mapped.body
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(mapped.stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if !route.apiKey.isEmpty { upstream.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in route.extraHeaders { upstream.setValue(value, forHTTPHeaderField: name) }
        let session = self.session
        do {
            if mapped.stream {
                let (bytes, response) = try await session.bytes(for: upstream)
                guard let http = response as? HTTPURLResponse else { return Self.error(status: 502, message: "invalid upstream response") }
                guard (200..<300).contains(http.statusCode) else {
                    var body = Data()
                    for try await byte in bytes { body.append(byte); if body.count > 16384 { break } }
                    Log.agent.warning("代理上游返回错误", ["route": key, "status": "\(http.statusCode)"])
                    return Self.upstreamFailure(status: http.statusCode, body: body)
                }
                Log.agent.info("代理开始流式转发", ["route": key, "model": mapped.model, "ms": "\(OMLogger.milliseconds(since: started))"])
                return .stream(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"], body: Self.translate(bytes: bytes, model: mapped.model, route: key))
            }
            let (data, response) = try await session.data(for: upstream)
            guard let http = response as? HTTPURLResponse else { return Self.error(status: 502, message: "invalid upstream response") }
            guard (200..<300).contains(http.statusCode) else {
                Log.agent.warning("代理上游返回错误", ["route": key, "status": "\(http.statusCode)"])
                return Self.upstreamFailure(status: http.statusCode, body: data)
            }
            let body = try ProtocolMapping.anthropicResponse(fromOpenAI: data, model: mapped.model)
            Log.agent.info("代理完成转发", ["route": key, "model": mapped.model, "ms": "\(OMLogger.milliseconds(since: started))"])
            return .full(status: 200, headers: ["Content-Type": "application/json"], body: body)
        } catch is CancellationError {
            return Self.error(status: 499, message: "cancelled")
        } catch let error as URLError {
            Log.agent.warning("代理无法连接上游", ["route": key, "code": "\(error.code.rawValue)"])
            return Self.error(status: 502, message: "cannot reach upstream: \(error.localizedDescription)")
        } catch {
            Log.agent.warning("代理转发失败", ["route": key, "error": "\(type(of: error))"])
            return Self.error(status: 502, message: "proxy failure")
        }
    }

    /// 把上游 SSE 字节流翻译成 Anthropic SSE;客户端断开时(流被取消)同时取消上游读取。
    private static func translate(bytes: URLSession.AsyncBytes, model: String, route: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                var translator = StreamTranslator(model: model)
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        for piece in translator.consume(payload: payload) { continuation.yield(Data(piece.utf8)) }
                        if translator.isFinished { break }
                    }
                    for piece in translator.finish() { continuation.yield(Data(piece.utf8)) }
                } catch is CancellationError {
                    // 客户端断开
                } catch {
                    Log.agent.warning("代理流式中断", ["route": route, "error": "\(type(of: error))"])
                    for piece in translator.failEvent(message: "upstream stream interrupted") { continuation.yield(Data(piece.utf8)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 辅助

    /// 上游 `/chat/completions` 地址。
    static func chatURL(_ base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/chat/completions") ?? base
    }

    /// 估算 token(每 4 个字符约 1 个 token),供 `/count_tokens` 使用。
    static func countTokens(_ body: Data) -> HTTPResult {
        let count = max(1, body.count / 4)
        return .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"input_tokens":\#(count)}"#.utf8))
    }

    static func error(status: Int, message: String) -> HTTPResult {
        .full(status: status, headers: ["Content-Type": "application/json"], body: ProtocolMapping.anthropicError(status: status, message: message))
    }

    /// 上游非 2xx:状态码透传,正文改写成 Anthropic 错误格式(OpenCode 免费层拒绝第三方客户端时给出明确提示)。
    static func upstreamFailure(status: Int, body: Data) -> HTTPResult {
        var message = ProtocolMapping.upstreamMessage(from: body)
        if String(data: body, encoding: .utf8)?.contains("FreeTierError") == true {
            message = String(localized: "该免费模型仅限 OpenCode 官方客户端使用(FreeTierError)。请改用 OpenCode Go 或自己的付费 API Key。")
        }
        message = LogRedactor.redact(message)
        return error(status: status, message: message.isEmpty ? "upstream error \(status)" : message)
    }
}
