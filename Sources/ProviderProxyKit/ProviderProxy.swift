// @author ixxxxoooo
// 模型网关代理:Claude Code 只会说 Anthropic Messages 协议,所有第三方模型经本代理接入。
//
// 流程:Claude Code → `http://127.0.0.1:端口/<令牌>/v1/messages` → 按请求里的槽位别名选目标 →
//   - Anthropic 协议厂商:改写 model 与鉴权头后原样透传(分块流式,不解析正文);
//   - OpenAI 协议厂商:转换为 `/chat/completions`,流式响应翻译回 Anthropic SSE。
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
    /// Anthropic 协议的鉴权方式:true 用 `x-api-key`,false 用 `Authorization: Bearer`
    public var usesAPIKeyHeader: Bool

    public init(upstreamBase: URL, apiKey: String, extraHeaders: [String: String] = [:], usesAPIKeyHeader: Bool = false) {
        self.upstreamBase = upstreamBase
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.usesAPIKeyHeader = usesAPIKeyHeader
    }
}

/// 上游使用的线协议。
public enum ProxyWire: Sendable, Equatable {
    /// Anthropic Messages(透传)
    case anthropic
    /// OpenAI Chat Completions(转换)
    case openAI
}

/// 一个路由目标:协议、上游信息与要发给上游的模型名。
public struct ProxyTarget: Sendable {
    public var wire: ProxyWire
    public var route: ProxyRoute
    /// 发给上游的模型名;nil 表示沿用请求里的模型名
    public var model: String?
    /// 日志里的标识(不含密钥)
    public var label: String

    public init(wire: ProxyWire, route: ProxyRoute, model: String? = nil, label: String = "route") {
        self.wire = wire
        self.route = route
        self.model = model
        self.label = label
    }
}

/// 协议转换代理(应用内共享一个实例,首次注册路由时才启动监听)。
///
/// 监听由 `LocalGateway` 提供(与 Bridge 的 HTTP MCP 共用一个回环端口)。
public actor ProviderProxy {
    /// 应用共享实例。
    public static let shared = ProviderProxy()

    private let gateway: LocalGateway
    /// 路由键(如会话/映射标识)→ 令牌
    private var tokens: [String: String] = [:]
    private let streamer: UpstreamStreamer

    /// 创建代理。
    /// - Parameters:
    ///   - configuration: 上游会话配置(测试可注入)
    ///   - gateway: 本机网关(测试可注入独立实例)
    public init(configuration: URLSessionConfiguration? = nil, gateway: LocalGateway = .shared) {
        self.gateway = gateway
        self.streamer = UpstreamStreamer(configuration: configuration)
    }

    /// 注册(或更新)一条只有单个 OpenAI 协议上游的路由(请求里的模型名原样发给上游)。
    /// - Parameters:
    ///   - key: 路由键(同一键重复注册沿用同一令牌,已建立的会话不会失效)
    ///   - route: 上游信息
    /// - Returns: 交给 Claude Code 作为 `ANTHROPIC_BASE_URL` 的本地地址
    /// - Throws: 监听启动失败
    public func register(key: String, route: ProxyRoute) async throws -> URL {
        try await register(key: key, targets: [:], fallback: ProxyTarget(wire: .openAI, route: route, label: key))
    }

    /// 注册(或更新)一条按模型别名分发的路由。
    /// - Parameters:
    ///   - key: 路由键
    ///   - targets: 模型别名 → 目标(别名即 Claude Code 请求里的 `model`)
    ///   - fallback: 别名未命中(如 Claude Code 内部发出的其他模型名)时使用的目标
    /// - Returns: 本地基础地址
    /// - Throws: 监听启动失败
    public func register(key: String, targets: [String: ProxyTarget], fallback: ProxyTarget) async throws -> URL {
        let handler: LocalGateway.Handler = { [weak self] request in
            guard let self else { return Self.error(status: 503, message: "proxy stopped") }
            return await self.handle(request, targets: targets, fallback: fallback)
        }
        let registered = try await gateway.register(token: tokens[key], handler: handler)
        tokens[key] = registered.token
        return registered.url
    }

    /// 注销一条路由。
    /// - Parameter key: 路由键
    public func unregister(key: String) async {
        guard let token = tokens.removeValue(forKey: key) else { return }
        await gateway.unregister(token: token)
    }

    /// 注销全部路由(不停止共享监听)。
    public func shutdown() async {
        for token in tokens.values { await gateway.unregister(token: token) }
        tokens.removeAll()
    }

    // MARK: - 请求处理

    private func handle(_ request: HTTPRequest, targets: [String: ProxyTarget], fallback: ProxyTarget) async -> HTTPResult {
        let tail = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method.uppercased(), tail) {
        case ("POST", "/v1/messages"):
            let requested = ModelRewriter.peekModel(request.body) ?? ""
            let target = targets[requested] ?? fallback
            switch target.wire {
            case .anthropic: return await passthrough(request, requested: requested, target: target)
            case .openAI: return await forward(request, requested: requested, target: target)
            }
        case ("POST", "/v1/messages/count_tokens"):
            return Self.countTokens(request.body)
        case ("GET", "/v1/models"):
            return .full(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"data":[],"has_more":false}"#.utf8))
        default:
            return Self.error(status: 404, message: "unsupported endpoint")
        }
    }

    // MARK: Anthropic 透传

    private func passthrough(_ request: HTTPRequest, requested: String, target: ProxyTarget) async -> HTTPResult {
        let started = ContinuousClock.now
        let route = target.route
        let body = target.model.map { ModelRewriter.rewrite(request.body, to: $0) } ?? request.body
        var upstream = URLRequest(url: Self.messagesURL(route.upstreamBase), cachePolicy: .reloadIgnoringLocalCacheData)
        upstream.httpMethod = "POST"
        upstream.httpBody = body
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(request.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let beta = request.headers["anthropic-beta"] { upstream.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        if let accept = request.headers["accept"] { upstream.setValue(accept, forHTTPHeaderField: "Accept") }
        if !route.apiKey.isEmpty {
            if route.usesAPIKeyHeader { upstream.setValue(route.apiKey, forHTTPHeaderField: "x-api-key") } else { upstream.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization") }
        }
        for (name, value) in route.extraHeaders { upstream.setValue(value, forHTTPHeaderField: name) }
        do {
            let response = try await streamer.send(upstream)
            guard (200..<300).contains(response.http.statusCode) else {
                let failure = await UpstreamStreamer.collect(response)
                Log.agent.warning("代理上游返回错误", ["route": target.label, "status": "\(response.http.statusCode)", "wire": "anthropic"])
                return Self.upstreamFailure(status: response.http.statusCode, body: failure)
            }
            Log.agent.info("代理开始透传", ["route": target.label, "alias": requested, "model": target.model ?? requested, "ms": "\(OMLogger.milliseconds(since: started))"])
            var headers = ["Cache-Control": "no-cache"]
            headers["Content-Type"] = response.http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            return .stream(status: response.http.statusCode, headers: headers, body: Self.relay(response.body, label: target.label, started: started))
        } catch is CancellationError {
            return Self.error(status: 499, message: "cancelled")
        } catch let error as URLError {
            Log.agent.warning("代理无法连接上游", ["route": target.label, "code": "\(error.code.rawValue)"])
            return Self.error(status: 502, message: "cannot reach upstream: \(error.localizedDescription)")
        } catch {
            Log.agent.warning("代理转发失败", ["route": target.label, "error": "\(type(of: error))"])
            return Self.error(status: 502, message: "proxy failure")
        }
    }

    /// 原样转发上游分块;客户端断开(流被放弃)时上游任务随之取消。
    private static func relay(_ body: AsyncThrowingStream<Data, Error>, label: String, started: ContinuousClock.Instant) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                var summary = StreamSummary(route: label, wire: "anthropic", started: started)
                do {
                    for try await chunk in body {
                        summary.noteChunk(bytes: chunk.count)
                        continuation.yield(chunk)
                    }
                } catch is CancellationError {
                    summary.outcome = "cancelled"
                } catch {
                    summary.outcome = "error"
                    Log.agent.warning("代理透传中断", ["route": label, "error": "\(type(of: error))"])
                }
                summary.log()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: OpenAI 转换

    private func forward(_ request: HTTPRequest, requested: String, target: ProxyTarget) async -> HTTPResult {
        let started = ContinuousClock.now
        let route = target.route
        let key = target.label
        let mapped: MappedRequest
        // OpenAI 官方端点:带上缓存路由键(按路由+模型稳定),让同一会话的多轮请求更容易命中前缀缓存
        let cacheKey = route.upstreamBase.host == "api.openai.com" ? "oma-\(key)-\(target.model ?? requested)" : nil
        do { mapped = try ProtocolMapping.openAIRequest(fromAnthropic: request.body, model: target.model, promptCacheKey: cacheKey) } catch {
            return Self.error(status: 400, message: "invalid request body")
        }
        var upstream = URLRequest(url: Self.chatURL(route.upstreamBase), cachePolicy: .reloadIgnoringLocalCacheData)
        upstream.httpMethod = "POST"
        upstream.httpBody = mapped.body
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(mapped.stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if !route.apiKey.isEmpty { upstream.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in route.extraHeaders { upstream.setValue(value, forHTTPHeaderField: name) }
        do {
            let response = try await streamer.send(upstream)
            guard (200..<300).contains(response.http.statusCode) else {
                let failure = await UpstreamStreamer.collect(response)
                Log.agent.warning("代理上游返回错误", ["route": key, "status": "\(response.http.statusCode)", "wire": "openai"])
                return Self.upstreamFailure(status: response.http.statusCode, body: failure)
            }
            if mapped.stream {
                Log.agent.info("代理开始流式转发", ["route": key, "alias": requested, "model": mapped.model, "ms": "\(OMLogger.milliseconds(since: started))"])
                return .stream(status: 200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"], body: Self.translate(chunks: response.body, model: mapped.model, route: key, started: started))
            }
            var data = Data()
            for try await chunk in response.body { data.append(chunk) }
            let body = try ProtocolMapping.anthropicResponse(fromOpenAI: data, model: mapped.model)
            Log.agent.info("代理完成转发", ["route": key, "alias": requested, "model": mapped.model, "ms": "\(OMLogger.milliseconds(since: started))"])
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

    /// 把上游 SSE 分块翻译成 Anthropic SSE;客户端断开时(流被取消)同时取消上游读取。
    private static func translate(chunks: AsyncThrowingStream<Data, Error>, model: String, route: String, started: ContinuousClock.Instant) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                var translator = StreamTranslator(model: model)
                var splitter = LineSplitter()
                var summary = StreamSummary(route: route, wire: "openai", started: started)
                func handle(_ line: String) -> Bool {
                    guard line.hasPrefix("data:") else { return false }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    let convertStart = ContinuousClock.now
                    for piece in translator.consume(payload: payload) { continuation.yield(Data(piece.utf8)) }
                    summary.convertMicros += OMLogger.microseconds(since: convertStart)
                    return translator.isFinished
                }
                defer { summary.log() }
                do {
                    outer: for try await chunk in chunks {
                        summary.noteChunk(bytes: chunk.count)
                        for line in splitter.push(chunk) where handle(line) { break outer }
                    }
                    if !translator.isFinished, let rest = splitter.flush() { _ = handle(rest) }
                    for piece in translator.finish() { continuation.yield(Data(piece.utf8)) }
                } catch is CancellationError {
                    summary.outcome = "cancelled"
                } catch {
                    summary.outcome = "error"
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

    /// 上游 `/v1/messages` 地址(Anthropic 协议基础地址不含 `/v1`)。
    static func messagesURL(_ base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/v1/messages") ?? base
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
        if let hint = UpstreamHints.message(for: body) { message = hint }
        message = LogRedactor.redact(message)
        return error(status: status, message: message.isEmpty ? "upstream error \(status)" : message)
    }
}

/// 一次代理流的汇总:首块耗时、块数、字节数、总耗时与协议转换耗时,流结束时输出一条 `代理流结束`。
/// 不记录任何正文与密钥,`route` 只是路由标签。
struct StreamSummary {
    let route: String
    let wire: String
    let started: ContinuousClock.Instant
    var chunks = 0
    var bytes = 0
    var firstChunkMs: Int?
    /// OpenAI → Anthropic 转换累计耗时(微秒)。
    var convertMicros = 0
    /// completed / cancelled / error。
    var outcome = "completed"

    init(route: String, wire: String, started: ContinuousClock.Instant) {
        self.route = route; self.wire = wire; self.started = started
    }

    /// 记录收到一块数据。
    mutating func noteChunk(bytes count: Int) {
        if firstChunkMs == nil { firstChunkMs = OMLogger.milliseconds(since: started) }
        chunks += 1
        bytes += count
    }

    /// 输出汇总日志(已取消按 info,出错按 warning)。
    func log() {
        let totalMicros = OMLogger.microseconds(since: started)
        PerfStats.shared.record(name: "代理流(\(wire))", micros: totalMicros)
        var fields = [
            "route": route, "wire": wire, "outcome": outcome,
            "firstChunkMs": firstChunkMs.map(String.init) ?? "-",
            "chunks": "\(chunks)", "bytes": "\(bytes)", "totalMs": "\(totalMicros / 1000)",
        ]
        if wire == "openai" { fields["convertMs"] = String(format: "%.1f", Double(convertMicros) / 1000) }
        if outcome == "error" { Log.perf.warning("代理流结束", fields) } else { Log.perf.info("代理流结束", fields) }
    }
}
