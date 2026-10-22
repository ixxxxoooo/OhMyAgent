// @author ixxxxoooo
// 图表悬停提示:鼠标在绘图区移动时,按位置换算出提示文字,经全应用统一的 omTooltip 面板显示。

import Charts
import DesignSystem
import SwiftUI

/// 图表悬停提示修饰器。
private struct ChartHoverTipModifier: ViewModifier {
    /// 由图表代理与绘图区内坐标换算提示文字,返回 nil 表示该处无提示。
    let text: (ChartProxy, CGPoint) -> String?
    @State private var owner = UUID()
    @State private var current = ""

    /// 在图表上叠一层透明悬停层。
    /// - Parameter content: 原图表
    /// - Returns: 带悬停提示的图表
    func body(content: Content) -> some View {
        content
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let plot = proxy.plotFrame else { return }
                                let origin = geo[plot].origin
                                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                                let next = text(proxy, local) ?? ""
                                guard next != current else { return }
                                current = next
                                if next.isEmpty { OMTooltipCenter.shared.hide(owner: owner) }
                                else { OMTooltipCenter.shared.schedule(owner: owner, text: next, icon: nil) }
                            case .ended:
                                current = ""
                                OMTooltipCenter.shared.hide(owner: owner)
                            }
                        }
                }
            }
            .onDisappear { OMTooltipCenter.shared.hide(owner: owner) }
    }
}

extension View {
    /// 给图表加悬停提示。
    /// - Parameter text: 由图表代理与绘图区内坐标返回提示文字(空/nil 不显示)
    /// - Returns: 带悬停提示的图表
    func chartHoverTip(_ text: @escaping (ChartProxy, CGPoint) -> String?) -> some View {
        modifier(ChartHoverTipModifier(text: text))
    }
}
