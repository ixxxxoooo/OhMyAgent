// @author ixxxxoooo
// 流动效果(对标 kuku 的 shimmer):悬停时背景上扫过一条柔和高光;运行中的标题文字做流光。
// 仅在需要时才创建 TimelineView,并遵循「减弱动态效果」。

import DesignSystem
import SwiftUI

/// 背景高光扫过:一条柔和的亮带从左到右循环平移。
struct FlowSweep: View {
    /// 一次扫过的周期(秒)
    var period: Double = 2.2
    /// 亮带峰值不透明度
    var opacity: Double = 0.09
    var cornerRadius: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                GeometryReader { geometry in
                    let band = geometry.size.width * 0.5
                    LinearGradient(colors: [.clear, OMColors.primaryText.opacity(opacity), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + phase * (geometry.size.width + band))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

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
                            LinearGradient(colors: [.clear, OMColors.primaryText, .clear], startPoint: .leading, endPoint: .trailing)
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
