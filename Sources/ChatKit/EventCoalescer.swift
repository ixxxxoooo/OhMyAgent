// @author ixxxxoooo
// 事件合并器:在后台线程接收高频事件,按窗口(默认 16ms,约一帧)成批投递给主 actor,
// 避免流式输出每个 token 都触发一次 UI 更新。批次通过 AsyncStream 严格按序投递。
// 窗口自适应:主线程处理一批越慢,下一批的窗口越长(合并更多事件、更少次更新),保证主线程始终有余量响应输入与滚动。

import ACPKit
import Foundation
import OMLog
import Synchronization

/// 自适应合并窗口:根据主线程处理一批的耗时(指数滑动平均)决定下一个窗口长度。
/// 目标是让主线程处理事件的占空比不超过约一半:窗口 ≈ 2 × 处理耗时,但不短于基础窗口、不长于上限。
public struct AdaptiveWindow: Sendable, Equatable {
    /// 基础窗口(约一帧)
    public let base: Duration
    /// 窗口上限(再长流式文字就明显一顿一顿)
    public let ceiling: Duration
    /// 处理耗时的滑动平均(毫秒)
    public private(set) var costMilliseconds: Double = 0

    /// - Parameters:
    ///   - base: 基础窗口
    ///   - ceiling: 窗口上限;不会小于基础窗口
    public init(base: Duration, ceiling: Duration = .milliseconds(80)) {
        self.base = base
        self.ceiling = max(base, ceiling)
    }

    /// 记录一批的处理耗时。
    /// - Parameter elapsed: 主线程应用这一批所用时间
    public mutating func record(_ elapsed: Duration) {
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        // 变慢时反应快(权重大),变快时缓慢恢复,避免窗口来回抖动
        let weight = ms > costMilliseconds ? 0.5 : 0.15
        costMilliseconds += (ms - costMilliseconds) * weight
    }

    /// 下一个合并窗口。
    public var interval: Duration {
        let wanted = Duration.milliseconds(costMilliseconds * 2)
        return min(ceiling, max(base, wanted))
    }
}

/// 事件合并器。
public final class EventCoalescer: Sendable {
    /// 事件积压(生产:`push`;消费:`SessionModel` 的批处理循环)。所有会话共用,反映整体是否来得及应用。
    public static let backlog = StreamBacklog(name: "backlog.events", warnDepth: 5000)
    private struct State {
        var buffer: [ClientEvent] = []
        var scheduled = false
        var pushed = 0
        var applied = 0
        var window: AdaptiveWindow
    }

    private let state: Mutex<State>
    private let continuation: AsyncStream<[ClientEvent]>.Continuation
    /// 合并后的批次流,只应有一个消费者。
    public let batches: AsyncStream<[ClientEvent]>

    /// 创建合并器。
    /// - Parameter interval: 基础合并窗口,默认 16ms;主线程处理变慢时会自动加长
    public init(interval: Duration = .milliseconds(16)) {
        self.state = Mutex(State(window: AdaptiveWindow(base: interval)))
        let (stream, continuation) = AsyncStream<[ClientEvent]>.makeStream(bufferingPolicy: .unbounded)
        self.batches = stream
        self.continuation = continuation
    }

    /// 推入一个事件;可在任意线程调用。
    /// - Parameter event: 事件
    public func push(_ event: ClientEvent) {
        Self.backlog.produced()
        let schedule = state.withLock { state -> Duration? in
            state.buffer.append(event)
            state.pushed += 1
            if state.scheduled { return nil }
            state.scheduled = true
            return state.window.interval
        }
        guard let interval = schedule else { return }
        Task.detached(priority: .userInitiated) { [self] in
            try? await Task.sleep(for: interval)
            flush()
        }
    }

    /// 立即投递缓冲中的事件。
    /// 同一条消息里相邻的文本增量先合并成一个事件(见 `merge`),主线程每批每条消息只追加一次文本、只触发一次观察通知。
    public func flush() {
        let (batch, merged) = state.withLock { state -> ([ClientEvent], Int) in
            state.scheduled = false
            let original = state.buffer
            state.buffer.removeAll(keepingCapacity: true)
            let batch = Self.merge(original)
            // 被合并掉的事件不会再经过 `markApplied`/积压消费:这里直接记为已应用
            let dropped = original.count - batch.count
            state.applied += dropped
            return (batch, dropped)
        }
        if merged > 0 { Self.backlog.consumed(merged) }
        if !batch.isEmpty { continuation.yield(batch) }
    }

    /// 合并批次里相邻的文本增量:同会话、同种消息块(用户/助手/思考)、同 messageId、都是纯文本时拼成一个事件。
    /// 只合并「相邻」事件,不会越过其他事件重排,时间线语义不变。
    /// - Parameter events: 一个窗口内按序到达的事件
    /// - Returns: 合并后的事件(顺序不变)
    static func merge(_ events: [ClientEvent]) -> [ClientEvent] {
        guard events.count > 1 else { return events }
        var result: [ClientEvent] = []
        result.reserveCapacity(events.count)
        var pendingText: String?
        for event in events {
            if case .sessionUpdate(let id, let update) = event, let next = TextChunk(update),
               let last = result.last, case .sessionUpdate(let lastID, let lastUpdate) = last, lastID == id,
               let previous = TextChunk(lastUpdate), previous.isSameStream(as: next) {
                // 累加到 pendingText(就地追加),最后一次性生成合并后的事件,避免每次都重建 ContentBlock
                if pendingText == nil { pendingText = previous.text }
                pendingText?.append(next.text)
                result[result.count - 1] = .sessionUpdate(sessionId: id, update: next.rebuilt(text: pendingText ?? next.text))
                continue
            }
            pendingText = nil
            result.append(event)
        }
        return result
    }

    /// 纯文本增量的拆解视图(用户/助手/思考三类)。
    private struct TextChunk {
        enum Kind { case user, agent, thought }
        let kind: Kind
        let messageId: String?
        var text: String

        init?(_ update: SessionUpdate) {
            switch update {
            case .userMessageChunk(let id, .text(let value)): self.init(kind: .user, messageId: id, text: value)
            case .agentMessageChunk(let id, .text(let value)): self.init(kind: .agent, messageId: id, text: value)
            case .agentThoughtChunk(let id, .text(let value)): self.init(kind: .thought, messageId: id, text: value)
            default: return nil
            }
        }

        private init(kind: Kind, messageId: String?, text: String) {
            self.kind = kind
            self.messageId = messageId
            self.text = text
        }

        func isSameStream(as other: TextChunk) -> Bool { kind == other.kind && messageId == other.messageId }

        func rebuilt(text: String) -> SessionUpdate {
            switch kind {
            case .user: .userMessageChunk(messageId: messageId, content: .text(text))
            case .agent: .agentMessageChunk(messageId: messageId, content: .text(text))
            case .thought: .agentThoughtChunk(messageId: messageId, content: .text(text))
            }
        }
    }

    /// 主 actor 应用完一批后调用,用于判断积压是否清空,并据处理耗时调整后续窗口。
    /// - Parameters:
    ///   - count: 本批事件数
    ///   - elapsed: 主线程应用这一批所用时间;nil 表示不据此调整窗口
    public func markApplied(_ count: Int, elapsed: Duration? = nil) {
        state.withLock { state in
            state.applied += count
            if let elapsed { state.window.record(elapsed) }
        }
    }

    /// 当前的合并窗口(测试与诊断用)。
    public var currentInterval: Duration { state.withLock { $0.window.interval } }

    /// 立即投递并等待已推入的事件全部被应用(有上限,避免异常时卡住)。
    /// - Parameter timeout: 最长等待
    /// - Returns: 是否已全部应用
    @discardableResult
    public func drain(timeout: Duration = .seconds(1)) async -> Bool {
        flush()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if state.withLock({ $0.applied >= $0.pushed }) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    /// 结束批次流。
    public func finish() {
        flush()
        continuation.finish()
    }
}

/// 事件屏障登记:读取协程遇到屏障通知时登记,回合结束处轮询等待(见 `ACPConnection.barrier`)。
public final class EventBarrier: Sendable {
    private let reached = Mutex(Set<String>())

    public init() {}

    /// 登记屏障已被读到。
    /// - Parameter token: 屏障标识
    public func signal(_ token: String) {
        reached.withLock { _ = $0.insert(token) }
    }

    /// 等待屏障被读到(有上限)。
    /// - Parameters:
    ///   - token: 屏障标识
    ///   - timeout: 最长等待
    /// - Returns: 是否在超时前到达
    public func wait(_ token: String, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if reached.withLock({ $0.remove(token) != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        reached.withLock { _ = $0.remove(token) }
        return false
    }
}
