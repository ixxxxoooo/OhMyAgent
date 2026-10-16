// @author ixxxxoooo
// Git 状态徽标:右栏 Git 图标上的小圆点与悬停提示。纯函数,不依赖界面。

import Foundation

/// 状态徽标:有未提交变更、未推送提交或待拉取提交时显示圆点。
public struct GitBadge: Sendable, Equatable {
    /// 未提交的文件数(含冲突与未跟踪)
    public var uncommitted: Int
    /// 待推送的提交数
    public var ahead: Int
    /// 待拉取的提交数
    public var behind: Int

    public init(uncommitted: Int = 0, ahead: Int = 0, behind: Int = 0) {
        self.uncommitted = uncommitted
        self.ahead = ahead
        self.behind = behind
    }

    /// 由状态快照生成徽标。
    public init(status: GitStatus) {
        self.init(uncommitted: status.changes.count, ahead: status.ahead, behind: status.behind)
    }

    /// 是否需要显示圆点。
    public var isVisible: Bool { uncommitted > 0 || ahead > 0 || behind > 0 }

    /// 是否存在冲突之外的“需要注意”的状态之外的轻提示:仅待拉取时用较弱的颜色。
    public var isOnlyBehind: Bool { uncommitted == 0 && ahead == 0 && behind > 0 }

    /// 悬停提示,例如「3 个未提交,2 个待推送」;都为零时为 nil。
    public var tooltip: String? {
        var parts: [String] = []
        if uncommitted > 0 { parts.append(String(localized: "\(uncommitted) 个未提交")) }
        if ahead > 0 { parts.append(String(localized: "\(ahead) 个待推送")) }
        if behind > 0 { parts.append(String(localized: "\(behind) 个待拉取")) }
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: ","))
    }
}

/// 轮询退避:状态不变时逐步拉长间隔,有变化立即恢复;大仓库(单次刷新耗时长)进一步放慢。
public enum PollBackoff {
    /// 计算下一次等待秒数。
    /// - Parameters:
    ///   - previous: 上一次等待秒数
    ///   - changed: 本次刷新是否发现变化
    ///   - duration: 本次刷新耗时(秒)
    ///   - base: 最短间隔
    ///   - maximum: 最长间隔
    public static func next(previous: Double, changed: Bool, duration: Double, base: Double = 3, maximum: Double = 15) -> Double {
        let interval = changed ? base : min(previous * 1.5, maximum)
        return min(max(interval, duration * 4, base), maximum * 2)
    }
}
