// @author ixxxxoooo
// 上游请求的分块流式读取:基于 URLSessionDataDelegate,按网络到达的块原样交付。
//
// 为什么不用 `URLSession.bytes(for:)`:它按字节迭代,SSE 长流里每个字节都要经过一次异步迭代,CPU 开销明显;
// 这里直接拿整块 `Data`,代理转发的额外开销接近零。取消语义:消费方放弃流(客户端断开)即取消上游任务。

import Foundation

/// 上游流式读取器(一个实例复用一个 URLSession)。
final class UpstreamStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 上游响应:状态行/头 + 分块正文。
    struct Response: Sendable {
        let http: HTTPURLResponse
        let body: AsyncThrowingStream<Data, Error>
    }

    /// 单个任务的状态。
    private final class State: @unchecked Sendable {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
        init(body: AsyncThrowingStream<Data, Error>.Continuation) { self.body = body }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private var session: URLSession?

    /// 创建读取器。
    /// - Parameters:
    ///   - requestTimeout: 两次数据之间的最长等待(秒)
    ///   - configuration: 会话配置(测试可注入)
    init(requestTimeout: TimeInterval = 300, configuration: URLSessionConfiguration? = nil) {
        super.init()
        let configuration = configuration ?? {
            let value = URLSessionConfiguration.ephemeral
            value.timeoutIntervalForRequest = requestTimeout
            value.waitsForConnectivity = false
            value.urlCache = nil
            value.requestCachePolicy = .reloadIgnoringLocalCacheData
            return value
        }()
        let queue = OperationQueue()
        queue.name = "com.ixxxxoooo.OhMyAgent.upstream"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    deinit { session?.invalidateAndCancel() }

    /// 发送请求并等待响应头;正文以流的形式继续到达。
    /// - Parameter request: 请求
    /// - Returns: 响应头与正文流
    /// - Throws: 连接失败或取消
    func send(_ request: URLRequest) async throws -> Response {
        guard let session else { throw URLError(.cancelled) }
        let task = session.dataTask(with: request)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        let state = State(body: continuation)
        continuation.onTermination = { [weak self] _ in
            // 消费方离开(客户端断开或读完):取消仍在进行的上游任务
            if task.state == .running || task.state == .suspended {
                task.cancel()
            }
            self?.remove(task.taskIdentifier)
        }
        let http: HTTPURLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<HTTPURLResponse, Error>) in
                state.head = head
                lock.withLock { states[task.taskIdentifier] = state }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return Response(http: http, body: stream)
    }

    /// 读取至多 `limit` 字节的正文(用于错误响应),然后放弃剩余部分。
    /// - Parameters:
    ///   - response: 上游响应
    ///   - limit: 字节上限
    /// - Returns: 已读取的数据
    static func collect(_ response: Response, limit: Int = 16384) async -> Data {
        var data = Data()
        do {
            for try await chunk in response.body {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {
            // 读取中断:返回已有部分
        }
        return data
    }

    private func remove(_ id: Int) {
        lock.withLock { _ = states.removeValue(forKey: id) }
    }

    private func state(for task: URLSessionTask) -> State? {
        lock.withLock { states[task.taskIdentifier] }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask) else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            state.head?.resume(returning: http)
            state.head = nil
            completionHandler(.allow)
        } else {
            state.head?.resume(throwing: URLError(.badServerResponse))
            state.head = nil
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state(for: dataTask)?.body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = lock.withLock({ states.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let head = state.head {
            state.head = nil
            head.resume(throwing: error ?? URLError(.badServerResponse))
        }
        if let error { state.body.finish(throwing: error) } else { state.body.finish() }
    }
}

/// 把分块 `Data` 切成 SSE 行(按 `\n` 分隔,去掉末尾 `\r`)。
struct LineSplitter: Sendable {
    private var buffer = Data()

    /// 喂入一块数据。
    /// - Parameter chunk: 新到达的数据
    /// - Returns: 已完整的行
    mutating func push(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var end = newline
            if end > buffer.startIndex, buffer[buffer.index(before: end)] == 0x0D { end = buffer.index(before: end) }
            lines.append(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// 流结束时取出残留(没有换行结尾的最后一行)。
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
