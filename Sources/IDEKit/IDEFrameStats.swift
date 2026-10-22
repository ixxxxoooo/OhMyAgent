// @author ixxxxoooo
// 帧间隔滚动统计(Perf HUD 的数据层,无视图、无定时器,便于测试)。
// 只保留最近 `capacity` 个帧间隔;掉帧按「超过 1.5 倍预期间隔」判定(与项目其余帧基准口径一致)。

import Foundation

/// 滚动窗口内的帧间隔统计。
public struct IDEFrameStats: Sendable, Equatable {
    /// 窗口内保留的最大帧数(默认约 2 秒 @60Hz)
    public let capacity: Int
    /// 预期帧间隔(毫秒),如 60Hz 为 16.67
    public var expectedMs: Double
    /// 最近的帧间隔(毫秒,旧→新)
    public private(set) var intervals: [Double] = []

    /// - Parameters:
    ///   - capacity: 窗口容量,小于 1 时取 1
    ///   - expectedMs: 预期帧间隔,非正数时取 16.67
    public init(capacity: Int = 120, expectedMs: Double = 1000.0 / 60.0) {
        self.capacity = max(capacity, 1)
        self.expectedMs = expectedMs > 0 ? expectedMs : 1000.0 / 60.0
    }

    /// 记录一个帧间隔;非有限值或非正数忽略(如暂停后恢复的首帧)。
    /// - Parameter intervalMs: 本帧与上一帧的间隔(毫秒)
    public mutating func record(_ intervalMs: Double) {
        guard intervalMs.isFinite, intervalMs > 0 else { return }
        intervals.append(intervalMs)
        if intervals.count > capacity { intervals.removeFirst(intervals.count - capacity) }
    }

    /// 清空窗口。
    public mutating func reset() { intervals.removeAll(keepingCapacity: true) }

    /// 平均帧率(帧/秒);无数据为 0。
    public var fps: Double {
        guard !intervals.isEmpty else { return 0 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        return 1000 / mean
    }

    /// 窗口内最长的帧间隔(毫秒)。
    public var maxMs: Double { intervals.max() ?? 0 }

    /// 窗口内帧间隔的 95 分位(毫秒)。
    public var p95Ms: Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted()
        return sorted[min(Int((Double(sorted.count) * 0.95).rounded(.down)), sorted.count - 1)]
    }

    /// 窗口内掉帧数(间隔超过 1.5 倍预期)。
    public var hitches: Int { intervals.filter { $0 > expectedMs * 1.5 }.count }
}
