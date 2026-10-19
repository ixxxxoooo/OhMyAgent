// @author ixxxxoooo
// 文字右端渐隐:用「背景色 → 透明」的渐变覆盖层代替 `.mask`。
// `.mask` 会让整个文字视图走离屏渲染(逐行、逐标签,侧栏几十行 + 标签条同时存在);
// 覆盖层只多画一个小矩形,视觉等价(前提:调用方给出该处真实的背景色)。

import SwiftUI

extension View {
    /// 在视图右端叠一条渐隐覆盖层,让溢出的内容淡出到背景里。
    /// - Parameters:
    ///   - width: 渐隐宽度
    ///   - base: 该处的不透明底色(侧栏/内容区背景)
    ///   - fill: 叠在底色之上的状态填充(悬停/选中等,半透明);无则不叠
    ///   - enabled: 是否启用(false 时原样返回,不叠覆盖层)
    @ViewBuilder
    func omFadeTrailingEdge(width: CGFloat, base: Color, fill: Color? = nil, enabled: Bool = true) -> some View {
        if enabled {
            overlay(alignment: .trailing) {
                ZStack {
                    LinearGradient(colors: [base.opacity(0), base], startPoint: .leading, endPoint: .trailing) // ui-lint:allow 仅作遮罩/淡出,非装饰
                    if let fill {
                        LinearGradient(colors: [fill.opacity(0), fill], startPoint: .leading, endPoint: .trailing) // ui-lint:allow 仅作遮罩/淡出,非装饰
                    }
                }
                .frame(width: width)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}
