// @author ixxxxoooo
// ACP 连接:基于任意传输实现 JSON-RPC 请求/响应关联、通知分发与反向请求处理。

import Foundation
import OMLog

/// 连接向上层投递的入站事件(通知与生命周期)。
public enum ACPInbound: Sendable {
    /// 对端发来的通知
    case notification(method: String, params: JSONValue?)
    /// 对端标准错误输出
    case stderr(String)
    /// 无法解析的行(用于诊断)
    case malformed(String)
    /// 连接关闭
    case closed(exitCode: Int32?)
}

/// 处理对端发起的请求(如 session/request_permission、fs/*、terminal/*)。
public protocol ACPRequestHandler: Sendable {
    /// 处理一条反向请求。
    /// - Parameters:
    ///   - method: 方法名
    ///   - params: 参数
    /// - Returns: 响应结果
    /// - Throws: 抛出 `JSONRPCError` 将以错误响应返回
    func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue
}

/// ACP 连接 actor。所有 I/O 解码、请求表维护均在该 actor 内完成,不占用主线程。
public actor ACPConnection {
    private let transport: any ACPTransport
    private var pending: [RequestID: CheckedContinuation<JSONValue, Error>] = [:]
    /// 请求的方法名与发出时刻,用于记录往返耗时。
    private var pendingInfo: [RequestID: (method: String, start: ContinuousClock.Instant)] = [:]
    private let log: OMLogger
    private var nextRequestID = 1
    private var handler: (any ACPRequestHandler)?
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    /// 入站事件流:通知、stderr、关闭。
    public nonisolated let inbound: AsyncStream<ACPInbound>
    private let inboundContinuation: AsyncStream<ACPInbound>.Continuation

    /// 创建连接。
    /// - Parameter transport: 传输实现
    /// - Parameter label: 日志中标识该连接的名称(如 agent id)
    public init(transport: any ACPTransport, label: String = "") {
        self.log = label.isEmpty ? Log.acp : Log.acp.with(["conn": label])
        self.transport = transport
        let (stream, continuation) = AsyncStream<ACPInbound>.makeStream(bufferingPolicy: .unbounded)
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    /// 屏障通知的方法名:调用方用它确认「此前已读到的通知都已进入事件流」。
    public static let barrierMethod = "_oma/barrier"

    /// 向入站流末尾插入屏障。入站流严格有序,消费者读到该屏障时,此前读到的所有通知必然已被消费。
    /// 用于回合结束时等待尾部事件(响应先于通知被处理会造成条目停在流式状态)。
    /// - Parameter token: 屏障标识
    public func barrier(_ token: String) {
        inboundContinuation.yield(.notification(method: Self.barrierMethod, params: ["token": .string(token)]))
    }

    /// 设置反向请求处理器。
    /// - Parameter handler: 处理器
    public func setRequestHandler(_ handler: any ACPRequestHandler) {
        self.handler = handler
    }

    /// 启动传输并开始读循环。
    public func start() throws {
        let events = try transport.start()
        readTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .line = event { StdioTransport.backlog.consumed() }
                await self.handle(event)
            }
        }
    }

    /// 发送请求并等待响应。
    /// - Parameters:
    ///   - method: 方法名
    ///   - params: 参数
    /// - Returns: 响应 result
    /// - Throws: `JSONRPCError`(对端错误)或连接关闭错误
    public func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        if isClosed {
            throw JSONRPCError(code: JSONRPCError.internalError, message: String(localized: "连接已关闭"))
        }
        let id = RequestID.int(nextRequestID)
        nextRequestID += 1
        pendingInfo[id] = (method, ContinuousClock.now)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.request(id: id, method: method, params: params))
                } catch {
                    pending[id] = nil
                    pendingInfo[id] = nil
                    log.error("请求发送失败", error: error, ["method": method])
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// 发送类型化请求。
    /// - Parameters:
    ///   - method: 方法名
    ///   - params: 可编码参数
    ///   - type: 响应类型
    /// - Returns: 解码后的响应
    public func request<P: Encodable, R: Decodable>(_ method: String, params: P, as type: R.Type) async throws -> R {
        let value = try await request(method, params: try JSONValue.from(params))
        return try value.decode(R.self)
    }

    /// 发送通知(无响应)。
    /// - Parameters:
    ///   - method: 方法名
    ///   - params: 参数
    public func notify(_ method: String, params: JSONValue? = nil) {
        try? send(.notification(method: method, params: params))
    }

    /// 关闭连接并停止传输。
    public func close() {
        guard !isClosed else { return }
        transport.stop()
        finish(exitCode: nil)
    }

    // MARK: - 内部

    /// 请求被调用方取消时通知对端并让本地请求以取消错误结束。
    private func cancelRequest(_ id: RequestID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let info = pendingInfo.removeValue(forKey: id) { log.info("请求被取消", ["method": info.method, "id": "\(id)"]) }
        if let raw = try? JSONValue.from(id) {
            try? send(.notification(method: "$/cancel_request", params: ["requestId": raw]))
        }
        continuation.resume(throwing: JSONRPCError(code: JSONRPCError.requestCancelled, message: String(localized: "请求已取消")))
    }

    private func send(_ message: JSONRPCMessage) throws {
        let data = try message.serialized()
        log.traffic("→", Self.summary(message), payload: String(decoding: data, as: UTF8.self))
        transport.send(data)
    }

    /// 协议流量日志的摘要:类型、方法名与 id。
    private static func summary(_ message: JSONRPCMessage) -> String {
        switch message {
        case .request(let id, let method, _): return "request \(method) #\(id)"
        case .notification(let method, _): return "notify \(method)"
        case .response(let id, _): return "response #\(id)"
        case .errorResponse(let id, let error): return "error #\(id.map { "\($0)" } ?? "-") code=\(error.code)"
        }
    }

    /// 记录一次请求的往返耗时;超过 2 秒升级为 warning(session/prompt 为长任务,不计入慢请求)。
    private func finishInfo(_ id: RequestID, failure: JSONRPCError?) {
        guard let info = pendingInfo.removeValue(forKey: id) else { return }
        let d = ContinuousClock.now - info.start
        let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        var fields = ["method": info.method, "id": "\(id)", "ms": "\(ms)"]
        if let failure {
            fields["code"] = "\(failure.code)"
            fields["message"] = failure.message
            log.warning("请求失败", fields)
        } else if ms > 2000, info.method != "session/prompt" {
            log.warning("请求较慢", fields)
        } else {
            log.debug("请求完成", fields)
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .line(let data):
            log.traffic("←", "line \(data.count)B", payload: String(decoding: data, as: UTF8.self))
            do {
                dispatch(try JSONRPCMessage.parse(data))
            } catch {
                log.warning("收到无法解析的行", ["error": "\(error)", "bytes": "\(data.count)", "head": String(decoding: data.prefix(200), as: UTF8.self)])
                inboundContinuation.yield(.malformed(String(decoding: data.prefix(512), as: UTF8.self)))
            }
        case .stderr(let text):
            inboundContinuation.yield(.stderr(text))
        case .closed(let code):
            finish(exitCode: code)
        }
    }

    private func dispatch(_ message: JSONRPCMessage) {
        switch message {
        case .response(let id, let result):
            finishInfo(id, failure: nil)
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .errorResponse(let id, let error):
            if let id {
                finishInfo(id, failure: error)
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        case .notification(let method, let params):
            inboundContinuation.yield(.notification(method: method, params: params))
        case .request(let id, let method, let params):
            guard let handler else {
                try? send(.errorResponse(id: id, error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "未实现: \(method)")))
                return
            }
            Task { [weak self] in
                let reply: JSONRPCMessage
                do {
                    let result = try await handler.handleRequest(method: method, params: params)
                    reply = .response(id: id, result: result)
                } catch let error as JSONRPCError {
                    reply = .errorResponse(id: id, error: error)
                } catch {
                    reply = .errorResponse(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription))
                }
                await self?.sendReply(reply)
            }
        }
    }

    private func sendReply(_ message: JSONRPCMessage) {
        try? send(message)
    }

    private func finish(exitCode: Int32?) {
        guard !isClosed else { return }
        isClosed = true
        log.info("连接关闭", ["exit": exitCode.map { "\($0)" } ?? "-", "pending": "\(pending.count)"])
        pendingInfo.removeAll()
        let error = JSONRPCError(code: JSONRPCError.internalError, message: String(localized: "连接已关闭"))
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        inboundContinuation.yield(.closed(exitCode: exitCode))
        inboundContinuation.finish()
        readTask?.cancel()
    }
}
