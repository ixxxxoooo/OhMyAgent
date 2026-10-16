// @author ixxxxoooo
// 标签保活(LRU):最近使用的若干标签的视图保持挂载,切换时无需重建编辑器/重新高亮;
// 会话标签常驻(重建整条时间线代价很高),其余标签超出上限后按最久未使用卸载。

import Foundation

/// 一个标签组内的保活状态(纯值类型,便于测试)。
public struct TabKeepAlive: Equatable, Sendable {
    /// 同时保活的非会话标签上限(含当前激活标签)。
    public static let defaultLimit = 5

    /// 最近使用顺序,最近的在前。
    public private(set) var order: [UUID] = []
    public let limit: Int

    /// - Parameter limit: 非会话标签的保活上限(至少 1)
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
        var kept = 0
        order = order.filter { tabID in
            if resident.contains(tabID) { return true }
            kept += 1
            return kept <= limit
        }
    }

    /// 需要挂载的标签:按组内原有顺序返回(保持视图身份稳定),并保证激活标签一定在内。
    public func mounted(in tabs: [WorkbenchTab], active: UUID?) -> [WorkbenchTab] {
        let keep = Set(order)
        return tabs.filter { keep.contains($0.id) || $0.id == active }
    }
}

extension WorkbenchTab {
    /// 会话标签常驻,不参与 LRU 淘汰。
    var isResident: Bool {
        if case .chat = kind { return true }
        return false
    }
}
