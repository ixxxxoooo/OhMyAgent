// @author ixxxxoooo
// 侧栏分隔条:1pt 细线 + 更宽的不可见拖动热区;拖动调整宽度;双击恢复默认宽度(右栏再双击展开到约半个窗口)。
// 取代原生 NavigationSplitView / inspector 的分隔条:原生列是 NSHostingView,会抢走窗口顶部浮层按钮的点击。

import DesignSystem
import SwiftUI
import WorkbenchKit

/// 侧栏分隔条。
/// 拖动中只写 `PanelDragState` 的临时值(不触碰整个 `WorkbenchLayout`,避免逐 tick 全局失效),
/// 松手、双击、无障碍调节时才一次性提交到布局。
struct PanelResizer: View {
    let workbench: WorkbenchModel
    /// 被调整的尺寸维度
    let dimension: PanelDimension
    /// 该列所在的物理一侧(决定拖动方向)
    let side: PanelSide
    /// 双击恢复的默认宽度
    let defaultWidth: Double
    /// 开始拖动时的宽度(拖动期间面板自身在移动,所以用全局坐标计算位移)
    @State private var base: Double?

    /// 当前有效宽度(只在手势/无障碍回调里读取,body 不订阅布局)。
    private var currentWidth: Double {
        workbench.panelDrag.effective(dimension, committed: workbench.layout)
    }

    /// 该维度允许的最大宽度:右栏取「窗口 − 项目栏 − 中栏最小宽度(与布局的 280 一致)」,
    /// 即布局实际放得下的最宽值;超过它只会让存储宽度大于显示宽度,拖回来时要先「空拖」一段才有反应。项目栏用静态范围。
    private var maximumWidth: Double {
        guard dimension == .rightWidth else { return dimension.range.upperBound }
        return PanelMetrics.rightMax(window: TerminalDragState.shared.workspaceFrame.width, layout: workbench.layout)
    }

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
                                let start = base ?? min(currentWidth, maximumWidth)
                                if base == nil { base = start }
                                let range = dimension.range.lowerBound...max(dimension.range.lowerBound, min(dimension.range.upperBound, maximumWidth))
                                let next = PanelMetrics.resized(base: start, translation: Double(value.translation.width), side: side, range: range)
                                workbench.panelDrag.update(next, for: dimension)
                            }
                            .onEnded { _ in
                                base = nil
                                workbench.commitPanelDrag(dimension)
                            }
                    )
                    .onTapGesture(count: 2) {
                        // 右栏:默认宽度 ↔ 展开到约半个窗口;项目栏:恢复默认
                        let target = dimension == .rightWidth
                            ? PanelMetrics.doubleClickTarget(current: currentWidth, defaultWidth: defaultWidth, maximum: maximumWidth, window: TerminalDragState.shared.workspaceFrame.width)
                            : defaultWidth
                        workbench.setPanelDimension(dimension, to: target)
                    }
            }
            .accessibilityLabel(side == .left ? String(localized: "调整左栏宽度") : String(localized: "调整右栏宽度"))
            .accessibilityAdjustableAction { direction in
                let step: Double = 20
                switch direction {
                case .increment: workbench.setPanelDimension(dimension, to: currentWidth + step)
                case .decrement: workbench.setPanelDimension(dimension, to: currentWidth - step)
                @unknown default: break
                }
            }
    }
}
