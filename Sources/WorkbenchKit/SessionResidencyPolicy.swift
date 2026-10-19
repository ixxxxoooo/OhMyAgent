// @author ixxxxoooo
// 会话驻留策略:决定哪些空闲会话应当休眠(结束 Agent 进程释放内存)。
// 纯函数,无副作用,便于测试;由 WorkbenchModel 定时调用并执行结果。

import Foundation

/// 驻留策略的一个会话快照。
public struct ResidencyCandidate: Sendable, Equatable {
    /// 会话键(调用方自定义,原样返回)
    public let id: String
    /// 是否占用着 Agent 进程(已连接或连接中)
    public let isLive: Bool
    /// 此刻是否允许休眠(空闲、无待处理事项、无后台任务,见 `SessionModel.canHibernate`)
    public let canHibernate: Bool
    /// 是否正显示在某个标签组/面板里(可见会话不休眠)
    public let isVisible: Bool
    /// 最近一次使用时间
    public let lastUsedAt: Date

    public init(id: String, isLive: Bool, canHibernate: Bool, isVisible: Bool, lastUsedAt: Date) {
        self.id = id
        self.isLive = isLive
        self.canHibernate = canHibernate
        self.isVisible = isVisible
        self.lastUsedAt = lastUsedAt
    }
}

/// 驻留上限。
public struct ResidencyLimits: Sendable, Equatable {
    /// 闲置多久后休眠(秒);0 表示不按闲置休眠
    public var idleSeconds: TimeInterval
    /// 同时保持运行的进程数上限;0 表示不限
    public var maxLive: Int

    public init(idleSeconds: TimeInterval, maxLive: Int) {
        self.idleSeconds = max(idleSeconds, 0)
        self.maxLive = max(maxLive, 0)
    }

    /// 系统内存紧张时的收紧版本:闲置 1 分钟即休眠,只留 1 个进程(可见/忙碌的会话本来就不受影响)。
    public var underPressure: ResidencyLimits {
        ResidencyLimits(idleSeconds: idleSeconds == 0 ? 60 : min(idleSeconds, 60), maxLive: 1)
    }
}

/// 驻留策略。
public enum SessionResidencyPolicy {
    /// 计算应休眠的会话。
    /// - Parameters:
    ///   - candidates: 全部会话快照
    ///   - limits: 驻留上限
    ///   - now: 当前时间
    /// - Returns: 应休眠的会话 ID,最久未用的在前
    public static func victims(candidates: [ResidencyCandidate], limits: ResidencyLimits, now: Date = Date()) -> [String] {
        let live = candidates.filter(\.isLive)
        let eligible = live.filter { $0.canHibernate && !$0.isVisible }.sorted { $0.lastUsedAt < $1.lastUsedAt }
        var chosen: [String] = []
        if limits.idleSeconds > 0 {
            chosen = eligible.filter { now.timeIntervalSince($0.lastUsedAt) >= limits.idleSeconds }.map(\.id)
        }
        if limits.maxLive > 0 {
            var remaining = live.count - chosen.count
            for candidate in eligible where remaining > limits.maxLive && !chosen.contains(candidate.id) {
                chosen.append(candidate.id)
                remaining -= 1
            }
        }
        let order = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($1.id, $0) })
        return chosen.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }
}
