// @author ixxxxoooo
// 会话流「跟随底部」的纯逻辑:何时贴底、何时放手、离开底部后累计多少条新内容。

import Foundation

/// 会话流滚动跟随状态。
///
/// 规则:
/// - 用户主动向上滚动(或松手时已离底部)→ 放手,流式输出不再把视图拽回底部;
/// - 回到距底部 `bottomTolerance` 以内 → 重新贴底并清空新消息计数;
/// - 放手期间新增的条目累计为 `unseen`,有任何内容更新则 `hasActivity` 为真,用于悬浮按钮提示。
public struct FollowState: Equatable, Sendable {
    /// 距底部多少点以内算「在底部」
    public static let bottomTolerance: CGFloat = 48

    /// 当前是否贴底(流式输出时自动滚到底)
    public private(set) var pinned = true
    /// 放手后新增的条目数
    public private(set) var unseen = 0
    /// 放手后是否有内容更新(流式增长、工具进度等)
    public private(set) var hasActivity = false

    private var anchorCount = 0
    private var lastOffset: CGFloat = 0
    private var lastContentHeight: CGFloat = 0

    public init() {}

    /// 悬浮按钮是否显示:不在底部时显示
    public var showsJumpButton: Bool { !pinned }

    /// 滚动几何变化。
    /// - Parameters:
    ///   - offsetY: 当前滚动偏移
    ///   - contentHeight: 内容总高度
    ///   - containerHeight: 可视高度
    ///   - userScrolling: 用户是否正在拖动/惯性滚动(非空闲阶段)
    ///   - entryCount: 当前时间线条目数
    public mutating func geometryChanged(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, userScrolling: Bool, entryCount: Int) {
        let distance = contentHeight - (offsetY + containerHeight)
        defer { lastOffset = offsetY; lastContentHeight = contentHeight }
        if distance <= Self.bottomTolerance {
            if !pinned || unseen > 0 || hasActivity { resetToBottom() }
            return
        }
        guard pinned else { return }
        // 内容高度没变而偏移变小 = 用户向上滚;或用户正在滚动且已离开底部
        let scrolledUp = contentHeight == lastContentHeight && offsetY < lastOffset - 1
        if userScrolling || scrolledUp {
            pinned = false
            anchorCount = entryCount
            unseen = 0
            hasActivity = false
        }
    }

    /// 时间线内容变化(新条目或流式增长)。
    /// - Returns: 是否应当自动滚到底部。
    public mutating func contentChanged(entryCount: Int, userScrolling: Bool) -> Bool {
        if pinned { return !userScrolling }
        hasActivity = true
        unseen = max(0, entryCount - anchorCount)
        return false
    }

    /// 点击「回到最新」:恢复贴底并清零计数。
    public mutating func jumpToLatest() { resetToBottom() }

    private mutating func resetToBottom() {
        pinned = true
        unseen = 0
        hasActivity = false
    }
}
