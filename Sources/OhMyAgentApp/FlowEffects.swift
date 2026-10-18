// @author ixxxxoooo
// 流动效果:运行中的会话标题文字做流光。
// 高亮带由 Core Animation 驱动(DesignSystem/LoopLayers.swift),不使用 TimelineView(.animation) 每帧重算视图;
// 并由 OMAnimationGate 门控(标签可见、应用可见、未减弱动态才动)。

import DesignSystem
import SwiftUI

/// 文字流光:文字本体偏淡,一条高亮带循环扫过(运行中的会话标题)。
private struct FlowingTextModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .foregroundStyle(OMColors.secondaryText)
                .omFlowOverlay(color: OMColors.primaryText)
        } else {
            content
        }
    }
}

extension View {
    /// 运行中的文字流光。
    /// - Parameter active: 是否启用
    func flowingText(_ active: Bool) -> some View {
        modifier(FlowingTextModifier(active: active))
    }
}
