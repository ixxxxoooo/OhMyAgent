// @author ixxxxoooo
// 仅监听 127.0.0.1 的极简 HTTP/1.1 服务器(基于 Network.framework)。
//
// 只支持代理需要的子集:一个请求一个连接(`Connection: close`)、Content-Length 请求体、
// 整体响应或不定长流式响应(SSE)。不做 TLS、不做 keep-alive。

import Foundation
import Network
import OMLog

/// 收到的 HTTP 请求。
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    /// 请求头(名称小写)
    public var headers: [String: String]
    public var body: Data
}

/// 处理器的返回值。
public enum HTTPResult: Sendable {
    /// 完整响应
    case full(status: Int, headers: [String: String], body: Data)
    /// 流式响应:每个 `Data` 原样写给客户端,流结束即关闭连接
    case stream(status: Int, headers: [String: String], body: AsyncStream<Data>)
}

/// 服务器启动失败。
public enum LoopbackServerError: Error, Equatable, Sendable {
    case listenerFailed(String)
}

/// 回环 HTTP 服务器。
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResult

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.ixxxxoooo.OhMyAgent.loopback-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private static let maxBody = 64 * 1024 * 1024
    private static let maxHeader = 64 * 1024

    /// 创建服务器。
    /// - Parameter handler: 请求处理器
    public init(handler: @escaping Handler) { self.handler = handler }

    /// 启动监听(随机端口,仅回环地址)。
    /// - Returns: 实际端口
    /// - Throws: `LoopbackServerError`
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw LoopbackServerError.listenerFailed(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() {
                        if let port = listener.port?.rawValue { continuation.resume(returning: port) }
                        else { continuation.resume(throwing: LoopbackServerError.listenerFailed("no port")) }
                    }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: LoopbackServerError.listenerFailed(error.localizedDescription)) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: LoopbackServerError.listenerFailed("cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return port
    }

    /// 停止监听。
    public func stop() {
        let current = lock.withLock { () -> NWListener? in
            let value = listener
            listener = nil
            return value
        }
        current?.cancel()
    }

    // MARK: - 连接处理

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        do {
            guard let request = try await readRequest(connection) else { return }
            let result = await handler(request)
            switch result {
            case .full(let status, let headers, let body):
                var all = headers
                all["Content-Length"] = String(body.count)
                try await send(connection, Self.head(status: status, headers: all) + body)
            case .stream(let status, let headers, let stream):
                try await send(connection, Self.head(status: status, headers: headers))
                for await chunk in stream { try await send(connection, chunk) }
            }
        } catch {
            // 客户端中途断开属正常现象,仅调试级别记录
            Log.agent.debug("代理连接结束", ["reason": "\(type(of: error))"])
        }
    }

    private func readRequest(_ connection: NWConnection) async throws -> HTTPRequest? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try await receive(connection) else { return nil }
            buffer.append(chunk)
            headerEnd = buffer.range(of: terminator)
            if headerEnd == nil && buffer.count > Self.maxHeader { return nil }
        }
        guard let headerEnd else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[line.startIndex..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard length >= 0, length <= Self.maxBody else { return nil }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard let chunk = try await receive(connection) else { return nil }
            body.append(chunk)
        }
        if body.count > length { body = body.prefix(length) }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var all = headers
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// 只允许取一次的标记(保证 continuation 只恢复一次)。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// 第一次调用返回 true,之后返回 false。
    func take() -> Bool {
        lock.withLock {
            if used { return false }
            used = true
            return true
        }
    }
}
