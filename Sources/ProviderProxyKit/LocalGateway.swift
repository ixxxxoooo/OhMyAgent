// @author ixxxxoooo
// 本机回环网关:应用内唯一的 127.0.0.1 监听,按路径第一段(随机令牌)分发给各处理器。
//
// 用途:模型协议代理(`ProviderProxy`)与 Bridge 的 HTTP MCP 共用同一个监听,
// 不再为 Bridge 单独拉起子进程或 Unix socket。令牌不可猜测,避免本机其他进程随意借用。

import Foundation
import OMLog

/// 本机回环网关。
public actor LocalGateway {
    /// 路由处理器:收到的 `HTTPRequest.path` 已去掉令牌段(如 `/v1/messages`)。
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResult

    /// 应用共享实例。
    public static let shared = LocalGateway()

    private var server: LoopbackHTTPServer?
    private var port: UInt16?
    /// 启动中的任务(actor 可重入,避免并发注册时重复启动监听)
    private var starting: Task<UInt16, Error>?
    private var routes: [String: Handler] = [:]

    /// 创建网关。
    public init() {}

    /// 注册一个处理器并返回其基础地址。
    /// - Parameters:
    ///   - token: 令牌(nil 则随机生成;同一令牌重复注册会替换处理器)
    ///   - handler: 请求处理器
    /// - Returns: 形如 `http://127.0.0.1:端口/令牌` 的基础地址
    /// - Throws: 监听启动失败
    public func register(token: String? = nil, handler: @escaping Handler) async throws -> (url: URL, token: String) {
        let port = try await ensureStarted()
        let value = token ?? Self.makeToken()
        guard !value.isEmpty, !value.contains("/"), let url = URL(string: "http://127.0.0.1:\(port)/\(value)") else {
            throw LoopbackServerError.listenerFailed("bad token")
        }
        routes[value] = handler
        return (url, value)
    }

    /// 注销处理器。
    /// - Parameter token: 令牌
    public func unregister(token: String) {
        routes.removeValue(forKey: token)
    }

    /// 已注册的路由数量(测试与诊断用)。
    public var routeCount: Int { routes.count }

    /// 当前监听端口(未启动为 nil)。
    public var currentPort: UInt16? { port }

    /// 停止监听并清空全部路由。
    public func shutdown() {
        server?.stop()
        server = nil
        port = nil
        starting = nil
        routes.removeAll()
    }

    /// 生成 32 位十六进制随机令牌。
    public static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - 内部

    private func ensureStarted() async throws -> UInt16 {
        if let port { return port }
        if let starting { return try await starting.value }
        let server = LoopbackHTTPServer { [weak self] request in
            guard let self else { return Self.notFound() }
            return await self.dispatch(request)
        }
        let task = Task { try await server.start() }
        starting = task
        do {
            let port = try await task.value
            self.server = server
            self.port = port
            starting = nil
            Log.agent.info("本机网关已启动", ["port": "\(port)"])
            return port
        } catch {
            starting = nil
            throw error
        }
    }

    /// 取出处理器后在 actor 之外执行,长请求不会阻塞注册/注销。
    private func dispatch(_ request: HTTPRequest) async -> HTTPResult {
        let (token, rest) = Self.split(path: request.path)
        guard let token, let handler = routes[token] else { return Self.notFound() }
        var stripped = request
        stripped.path = rest
        return await handler(stripped)
    }

    /// 拆分 `/令牌/其余` 路径(保留查询串在其余部分)。
    static func split(path: String) -> (token: String?, rest: String) {
        let trimmed = path.drop(while: { $0 == "/" })
        guard !trimmed.isEmpty else { return (nil, "/") }
        guard let slash = trimmed.firstIndex(where: { $0 == "/" || $0 == "?" }) else { return (String(trimmed), "/") }
        let token = String(trimmed[trimmed.startIndex..<slash])
        var rest = String(trimmed[slash...])
        if rest.hasPrefix("?") { rest = "/" + rest }
        return (token, rest)
    }

    private static func notFound() -> HTTPResult {
        .full(status: 404, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"unknown route"}"#.utf8))
    }
}
