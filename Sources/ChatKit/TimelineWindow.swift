// @author ixxxxoooo
// 时间线窗口化:长会话只渲染最近若干轮,更早的折成顶部的「显示更早的 N 轮对话」。
// 效果:`ForEach` 的差异比较、行身份签名、`LazyVStack` 滚过后不回收的行数都有上限,
// 内存与每次重新求值的成本不再随会话总长度线性增长。纯逻辑,无视图。

import Foundation

/// 时间线窗口。
@MainActor
public enum TimelineWindow {
    /// 默认渲染的最近轮数
    public static let defaultTurns = 40
    /// 每次点「显示更早」多展开的轮数
    public static let pageTurns = 40

    /// 窗口切片结果。
    public struct Slice {
        /// 窗口内的展示单元(保持原顺序)
        public let items: [TimelineItem]
        /// 被折在窗口之外的轮数
        public let hiddenTurns: Int
        /// 被折在窗口之外的展示单元数
        public let hiddenItems: Int

        public init(items: [TimelineItem], hiddenTurns: Int, hiddenItems: Int) {
            self.items = items
            self.hiddenTurns = hiddenTurns
            self.hiddenItems = hiddenItems
        }
    }

    /// 一个展示单元是否是新一轮的开头(非「引导」的用户消息)。
    private static func startsTurn(_ item: TimelineItem) -> Bool {
        guard case .entry(let entry) = item else { return false }
        return entry.kind == .user && !entry.isSteered
    }

    /// 各轮开头在 `items` 里的下标。
    private static func turnStarts(_ items: [TimelineItem]) -> [Int] {
        items.indices.filter { startsTurn(items[$0]) }
    }

    /// 取最近 `visibleTurns` 轮。第一个用户消息之前的单元(如开场提示)算在第一轮里。
    /// - Parameters:
    ///   - items: 全部展示单元
    ///   - visibleTurns: 窗口大小(轮数,至少 1)
    /// - Returns: 窗口切片;轮数没超过窗口时原样返回、不折叠
    public static func slice(_ items: [TimelineItem], visibleTurns: Int) -> Slice {
        let limit = max(visibleTurns, 1)
        let starts = turnStarts(items)
        guard starts.count > limit else { return Slice(items: items, hiddenTurns: 0, hiddenItems: 0) }
        let cut = starts[starts.count - limit]
        return Slice(items: Array(items[cut...]), hiddenTurns: starts.count - limit, hiddenItems: cut)
    }

    /// 要让某条用户消息出现在窗口里,窗口至少要多大。
    /// - Parameters:
    ///   - id: 目标条目 id(锚点跳转的用户消息)
    ///   - items: 全部展示单元
    ///   - visibleTurns: 当前窗口大小
    /// - Returns: 需要的窗口大小;目标已在窗口内或不存在时返回 nil
    public static func turnsToReveal(_ id: UUID, in items: [TimelineItem], visibleTurns: Int) -> Int? {
        let starts = turnStarts(items)
        guard let position = starts.firstIndex(where: { items[$0].id == id }) else { return nil }
        let needed = starts.count - position
        return needed > max(visibleTurns, 1) ? needed : nil
    }
}
