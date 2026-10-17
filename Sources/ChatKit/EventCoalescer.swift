// @author ixxxxoooo
// 事件合并器:在后台线程接收高频事件,按固定窗口(默认 12ms,约一帧)成批投递给主 actor,
// 避免流式输出每个 token 都触发一次 UI 更新。批次通过 AsyncStream 严格按序投递。

import ACPKit
import Foundation
import OMLog
import Synchronization

/// 事件合并器。
public final class EventCoalescer: Sendable {
    /// 事件积压(生产:`push`;消费:`SessionModel` 的批处理循环)。所有会话共用,反映整体是否来得及应用。
    public static let backlog = StreamBacklog(name: "backlog.events")
    private struct State {
        var buffer: [ClientEvent] = []
        var scheduled = false
    }

    private let state = Mutex(State())
    private let interval: Duration
    private let continuation: AsyncStream<[ClientEvent]>.Continuation
    /// 合并后的批次流,只应有一个消费者。
    public let batches: AsyncStream<[ClientEvent]>

    /// 创建合并器。
    /// - Parameter interval: 合并窗口,默认 12ms
    public init(interval: Duration = .milliseconds(12)) {
        self.interval = interval
        let (stream, continuation) = AsyncStream<[ClientEvent]>.makeStream(bufferingPolicy: .unbounded)
        self.batches = stream
        self.continuation = continuation
    }

    /// 推入一个事件;可在任意线程调用。
    /// - Parameter event: 事件
    public func push(_ event: ClientEvent) {
        Self.backlog.produced()
        let needsSchedule = state.withLock { state -> Bool in
            state.buffer.append(event)
            if state.scheduled { return false }
            state.scheduled = true
            return true
        }
        guard needsSchedule else { return }
        let interval = interval
        Task.detached(priority: .userInitiated) { [self] in
            try? await Task.sleep(for: interval)
            flush()
        }
    }

    /// 立即投递缓冲中的事件。
    public func flush() {
        let batch = state.withLock { state -> [ClientEvent] in
            state.scheduled = false
            let batch = state.buffer
            state.buffer.removeAll(keepingCapacity: true)
            return batch
        }
        if !batch.isEmpty { continuation.yield(batch) }
    }

    /// 结束批次流。
    public func finish() {
        flush()
        continuation.finish()
    }
}
