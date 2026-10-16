// @author ixxxxoooo
// 标签保活(LRU):最近使用的若干标签的视图保持挂载,切换时无需重建编辑器/重新高亮;
// 会话与终端标签常驻(重建时间线/终端视图代价很高),其余标签按「权重」计入预算,超出后按最久未使用卸载;
// 只有用户关闭标签,其对应视图才会被销毁。

import Foundation

/// 一个标签组内的保活状态(纯值类型,便于测试)。
public struct TabKeepAlive: Equatable, Sendable {
    /// 非常驻标签的保活预算(各类标签按权重计入,含当前激活标签)。
    public static let defaultLimit = 10

    /// 最近使用顺序,最近的在前。
    public private(set) var order: [UUID] = []
    public let limit: Int

    /// - Parameter limit: 非常驻标签的保活预算(至少 1)
    public init(limit: Int = TabKeepAlive.defaultLimit) {
        self.limit = max(limit, 1)
    }

    /// 记录一次激活并裁剪。
    /// - Parameters:
    ///   - id: 被激活的标签
    ///   - tabs: 当前组内全部标签(用于识别会话标签与剔除已关闭的标签)
    public mutating func activate(_ id: UUID?, in tabs: [WorkbenchTab]) {
        let alive = Set(tabs.map(\.id))
        order.removeAll { !alive.contains($0) }
        if let id, alive.contains(id) {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
        }
        let resident = Set(tabs.filter(\.isResident).map(\.id))
        let weights = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.keepAliveWeight) })
        var used = 0
        var keptAny = false
        order = order.filter { tabID in
            if resident.contains(tabID) { return true }
            let weight = weights[tabID] ?? 1
            // 最近使用的那个标签即使单个权重超过预算也要保留
            if !keptAny || used + weight <= limit {
                keptAny = true
                used += weight
                return true
            }
            return false
        }
    }

    /// 需要挂载的标签:按组内原有顺序返回(保持视图身份稳定),并保证激活标签一定在内。
    public func mounted(in tabs: [WorkbenchTab], active: UUID?) -> [WorkbenchTab] {
        let keep = Set(order)
        return tabs.filter { keep.contains($0.id) || $0.id == active }
    }
}

extension WorkbenchTab {
    /// 会话与终端标签常驻,不参与 LRU 淘汰。
    var isResident: Bool {
        switch kind {
        case .chat, .terminal: return true
        default: return false
        }
    }

    /// 保活权重:越重的视图(整条时间线、Diff、提交图)越快占满预算。
    var keepAliveWeight: Int {
        switch kind {
        case .subagent: return 3
        case .diff, .changes, .history: return 2
        default: return 1
        }
    }
}
