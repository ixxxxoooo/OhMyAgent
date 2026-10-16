// @author ixxxxoooo
// 侧栏分隔条:1pt 细线 + 更宽的不可见拖动热区;拖动调整宽度,双击恢复默认宽度。
// 取代原生 NavigationSplitView / inspector 的分隔条:原生列是 NSHostingView,会抢走窗口顶部浮层按钮的点击。

import DesignSystem
import SwiftUI
import WorkbenchKit

/// 侧栏分隔条。
struct PanelResizer: View {
    /// 被调整的宽度(绑定到 `WorkbenchLayout`)
    @Binding var width: Double
    let side: PanelSide
    /// 开始拖动时的宽度(拖动期间面板自身在移动,所以用全局坐标计算位移)
    @State private var base: Double?

    var body: some View {
        Rectangle()
            .fill(OMColors.hairline)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = base ?? width
                                if base == nil { base = start }
                                width = PanelMetrics.resized(base: start, translation: Double(value.translation.width), side: side)
                            }
                            .onEnded { _ in base = nil }
                    )
                    .onTapGesture(count: 2) { width = PanelMetrics.defaultWidth(for: side) }
            }
            .accessibilityLabel(side == .left ? String(localized: "调整左栏宽度") : String(localized: "调整右栏宽度"))
            .accessibilityAdjustableAction { direction in
                let step: Double = 20
                switch direction {
                case .increment: width = PanelMetrics.clamp(width + step, side: side)
                case .decrement: width = PanelMetrics.clamp(width - step, side: side)
                @unknown default: break
                }
            }
    }
}
