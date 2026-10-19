// @author ixxxxoooo
// 会话流容器 ChatView 拆出的叶子视图:把「会因滚动/流式高频变化的读取」隔离在 0 尺寸或小尺寸的子视图里,
// 使 ChatView.body(含输入区、全部浮层、锚点栏)不再随滚动帧率或流式批次整体重算。

import ChatKit
import DesignSystem
import SwiftUI

/// 时间线修订号监听器(0 尺寸叶子):流式每个批次 `revision` 自增,监听发生在这里,
/// 而不是 ChatView.body 里的 `.onChange(of: model.timeline.revision)`(后者会让整个 body 依赖 revision)。
struct TimelineRevisionDriver: View {
    let timeline: TimelineStore
    /// 修订号变化时执行(由 ChatView 提供,内部自行做帧内合并)
    let action: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: timeline.revision) { action() }
            .accessibilityHidden(true)
    }
}

/// 锚点跳转动作的稳定载体:引用类型、身份恒定,使 `ConversationAnchorRail` 的入参不随 ChatView 重算而变化,
/// SwiftUI 可以跳过它的重新求值。闭包本身不参与观察,每次 ChatView 求值时刷新。
@MainActor
final class AnchorJumpAction {
    /// 当前跳转处理(点击某条提问)
    var handler: (UUID) -> Void = { _ in }

    init() {}

    /// 触发跳转。
    func callAsFunction(_ id: UUID) { handler(id) }
}

/// 会话流上下边缘渐隐状态(可观察,只被 `TimelineEdgeFadeHost` 读取)。
@MainActor
@Observable
final class EdgeFadeModel {
    /// 当前需要渐隐的边缘
    var edges = TimelineEdgeFade.Edges(top: false, bottom: false)

    init() {}

    /// 更新边缘状态(相同则不写)。
    func update(_ next: TimelineEdgeFade.Edges) {
        if edges != next { edges = next }
    }
}

/// 渐隐遮罩宿主:读取 `EdgeFadeModel`,动画只作用在遮罩自身(`.animation(value:)`),
/// 不再通过 `withAnimation` 事务带动整个 ChatView 子树。
struct TimelineEdgeFadeHost: View {
    let model: EdgeFadeModel

    var body: some View {
        let edges = model.edges
        TimelineEdgeFade(edges: edges)
            .animation(omShouldReduceMotion() ? nil : OMMotion.standard, value: edges)
    }
}

/// 「回到最新」按钮宿主:读取 `FollowTracker` 与会话运行状态,ChatView.body 本身不订阅它们。
struct JumpToLatestHost: View {
    let follow: FollowTracker
    let model: SessionModel
    /// 点击回到最新(由 ChatView 提供滚动与吸顶复位)
    let onJump: () -> Void

    var body: some View {
        if follow.showsJumpButton {
            JumpToLatestButton(unseen: follow.unseen, hasActivity: follow.hasActivity || model.isRunning, action: onJump)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}
