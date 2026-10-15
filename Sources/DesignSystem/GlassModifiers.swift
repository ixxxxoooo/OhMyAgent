// @author ygw
// Liquid Glass 封装:玻璃仅用于功能区;降级时无缝替换为不透明材质。

import SwiftUI

public extension View {
    /// 在功能区应用玻璃效果;“减少透明度”或低电量时回退为不透明材质。
    /// - Parameters:
    ///   - shape: 形状
    ///   - tint: 可选着色
    ///   - interactive: 是否响应交互(按压、悬停)
    /// - Returns: 应用后的视图
    func omGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(OMGlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// 玻璃胶囊的便捷写法。
    func omGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        omGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// 纯色卡片:用于工具卡片、权限卡片等重要信息,不使用玻璃。
    /// - Parameter cornerRadius: 圆角
    func omSolidCard(cornerRadius: CGFloat = OMMetrics.cardRadius) -> some View {
        background(OMColors.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
    }
}

/// 玻璃修饰器。
struct OMGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    private let policy = MaterialPolicy.shared

    func body(content: Content) -> some View {
        if policy.useGlass {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(OMColors.opaqueChrome, in: shape)
                .overlay(shape.stroke(OMColors.hairline, lineWidth: 0.5))
        }
    }
}

/// 玻璃按钮组容器:玻璃开启时使用 `GlassEffectContainer` 合并采样;关闭时为普通容器。
public struct OMGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content
    private let policy = MaterialPolicy.shared

    /// 创建按钮组。
    /// - Parameters:
    ///   - spacing: 元素融合距离
    ///   - content: 内容
    public init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if policy.useGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
