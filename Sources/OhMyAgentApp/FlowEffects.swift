// @author ixxxxoooo
// 流动效果:运行中的会话标题文字做流光。
// 仅在需要时才创建 TimelineView,并遵循「减弱动态效果」。

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
                .overlay {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                        GeometryReader { geometry in
                            let band = max(geometry.size.width * 0.45, 28)
                            LinearGradient(colors: [.clear, OMColors.primaryText, .clear], startPoint: .leading, endPoint: .trailing) // ui-lint:allow 仅作遮罩/淡出,非装饰
                                .frame(width: band)
                                .offset(x: -band + phase * (geometry.size.width + band))
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
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
