// @author ixxxxoooo
// 吸顶用户消息的纯逻辑:向上滚动时,把当前回合的用户消息固定在会话流顶部;
// 下一条用户消息上来时,把前一条向上顶出(对标 Cursor)。无视图,便于测试。

import CoreGraphics
import Foundation

/// 吸顶目标解析。
public enum StickyUser {
    /// 解析结果。
    public struct Target: Equatable {
        /// 当前要吸顶的用户消息 ID
        public var stickyID: UUID
        /// 其后的下一条用户消息 ID(用于计算顶出位移;没有则 nil)
        public var nextID: UUID?
    }

    /// 解析吸顶目标。
    /// - Parameters:
    ///   - entries: 时间线条目(按顺序)
    ///   - topIndex: 当前可见的最靠上条目在 `entries` 中的下标;nil 表示未知
    ///   - userMinY: 各用户消息行在滚动视口中的顶边 Y(只含已渲染的行)
    ///   - pushZone: 顶出区高度:下一条用户消息顶边进入该范围时,前一条仍保持显示并被顶出
    /// - Returns: 目标;不需要吸顶时返回 nil
    @MainActor
    public static func resolve(entries: [TimelineEntry], topIndex: Int?, userMinY: [UUID: CGFloat], pushZone: CGFloat) -> Target? {
        guard let topIndex, entries.indices.contains(topIndex) else { return nil }
        let top = entries[topIndex]

        if top.kind == .user {
            let minY = userMinY[top.id] ?? .greatestFiniteMagnitude   // 还没有位置信息:视为完整可见
            // 当前用户消息的行已滚到顶边之上:它自己接管吸顶
            if minY < 0 { return Target(stickyID: top.id, nextID: nextUser(after: topIndex, in: entries)) }
            // 当前行刚进入顶出区:前一条用户消息仍在顶部,被它顶出
            if minY < pushZone, let previous = previousUser(before: topIndex, in: entries) {
                return Target(stickyID: entries[previous].id, nextID: top.id)
            }
            return nil
        }
        guard let previous = previousUser(before: topIndex, in: entries) else { return nil }
        return Target(stickyID: entries[previous].id, nextID: nextUser(after: previous, in: entries))
    }

    /// 顶出位移(≤ 0):下一条用户消息的顶边逼近吸顶卡底边时,吸顶卡整体上移。
    /// - Parameters:
    ///   - nextMinY: 下一条用户消息顶边 Y;nil 表示尚未渲染(不顶出)
    ///   - cardHeight: 吸顶卡高度
    ///   - topInset: 吸顶卡距顶部的留白
    ///   - gap: 两卡之间的间隙
    public static func pushOffset(nextMinY: CGFloat?, cardHeight: CGFloat, topInset: CGFloat = 8, gap: CGFloat = 8) -> CGFloat {
        guard let nextMinY else { return 0 }
        return min(0, nextMinY - topInset - cardHeight - gap)
    }

    /// 在 `entries` 中找 `index` 之前最近的一条用户消息下标。
    @MainActor
    static func previousUser(before index: Int, in entries: [TimelineEntry]) -> Int? {
        guard index > 0 else { return nil }
        for i in stride(from: index - 1, through: 0, by: -1) where entries[i].kind == .user && !entries[i].isSteered { return i }
        return nil
    }

    /// 在 `entries` 中找 `index` 之后最近的一条用户消息 ID。
    @MainActor
    static func nextUser(after index: Int, in entries: [TimelineEntry]) -> UUID? {
        guard index + 1 < entries.count else { return nil }
        return entries[(index + 1)...].first { $0.kind == .user && !$0.isSteered }?.id
    }
}
