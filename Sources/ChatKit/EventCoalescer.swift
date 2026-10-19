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
    public static let backlog = StreamBacklog(name: "backlog.events")
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
    public func flush() {
        let batch = state.withLock { state -> [ClientEvent] in
            state.scheduled = false
            let batch = state.buffer
            state.buffer.removeAll(keepingCapacity: true)
            return batch
        }
        if !batch.isEmpty { continuation.yield(batch) }
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
