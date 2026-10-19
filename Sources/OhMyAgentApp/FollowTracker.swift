// @author ixxxxoooo
// 会话流跟随状态的观察包装:`FollowState` 是值类型,滚动每帧写 `lastOffset/lastContentHeight` 会让持有它的
// `@State` 视图(ChatView,含输入区与全部浮层)按滚动帧率整体重算。
// 这里把「帧内暂存字段」留在 `@ObservationIgnored` 的结构体里,只有 `pinned/unseen/hasActivity`
// 真变化时才写被观察属性,读取这些属性的小叶子视图(回到最新按钮)才会刷新。

import ChatKit
import CoreGraphics
import Observation

/// 会话流跟随底部的可观察状态。
@MainActor
@Observable
final class FollowTracker {
    /// 当前是否贴底(流式输出时自动滚到底)
    private(set) var pinned = true
    /// 放手后新增的条目数
    private(set) var unseen = 0
    /// 放手后是否有内容更新
    private(set) var hasActivity = false

    /// 纯逻辑状态机(含逐帧暂存字段;不参与观察)
    @ObservationIgnored private var state = FollowState()

    /// 悬浮按钮是否显示:不在底部时显示
    var showsJumpButton: Bool { !pinned }

    /// 滚动几何变化(语义同 `FollowState.geometryChanged`)。
    func geometryChanged(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, userScrolling: Bool, entryCount: Int) {
        state.geometryChanged(offsetY: offsetY, contentHeight: contentHeight, containerHeight: containerHeight, userScrolling: userScrolling, entryCount: entryCount)
        publish()
    }

    /// 时间线内容变化。
    /// - Returns: 是否应当自动滚到底部
    func contentChanged(entryCount: Int, userScrolling: Bool) -> Bool {
        let shouldScroll = state.contentChanged(entryCount: entryCount, userScrolling: userScrolling)
        publish()
        return shouldScroll
    }

    /// 点击「回到最新」:恢复贴底并清零计数。
    func jumpToLatest() {
        state.jumpToLatest()
        publish()
    }

    /// 只在值真变化时写被观察属性,避免无谓的失效通知。
    private func publish() {
        if pinned != state.pinned { pinned = state.pinned }
        if unseen != state.unseen { unseen = state.unseen }
        if hasActivity != state.hasActivity { hasActivity = state.hasActivity }
    }
}
