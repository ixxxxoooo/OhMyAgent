// @author ixxxxoooo
// 循环动画的 Core Animation 实现:呼吸点、加载转圈、文字流光高亮带。
// 动画由渲染服务器驱动(单次添加 repeat = .infinity 的 CAAnimation),不再让 SwiftUI 每帧重算视图图;
// 是否运行由 `OMAnimationGate`(标签可见 + 应用可见 + 未减弱动态)决定。

import AppKit
import SwiftUI

/// 带「运行/停止」开关的循环动画图层视图基类。
@MainActor
class OMLoopLayerView: NSView {
    /// 是否运行循环动画;变化时自动添加/移除动画。
    var running = false {
        didSet { if oldValue != running { applyAnimations() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAnimations()
    }

    override func layout() {
        super.layout()
        layoutLayers()
        if running { applyAnimations() }
    }

    /// 子类:按当前尺寸摆放图层。
    func layoutLayers() {}

    /// 子类:按 `running` 添加或移除动画(需幂等)。
    func applyAnimations() {}

    /// 把 SwiftUI 颜色转为当前外观下的 CGColor。
    static func cgColor(_ color: Color) -> CGColor { NSColor(color).cgColor }
}

// MARK: - 呼吸点

/// 呼吸点:透明度 0.4↔1、缩放 0.78↔1 往复;停止时显示完整状态。
@MainActor
final class OMBreathingLayerView: OMLoopLayerView {
    private let shape = CAShapeLayer()
    private var duration: Double = 0.6
    private var ring = false
    private var lineWidth: CGFloat = 1.4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 更新外观参数。
    func configure(color: Color, ring: Bool, lineWidth: CGFloat, duration: Double) {
        self.ring = ring
        self.lineWidth = lineWidth
        let durationChanged = self.duration != duration
        self.duration = duration
        let cg = Self.cgColor(color)
        shape.fillColor = ring ? nil : cg
        shape.strokeColor = ring ? cg : nil
        shape.lineWidth = ring ? lineWidth : 0
        layoutLayers()
        if durationChanged, running { shape.removeAllAnimations(); applyAnimations() }
    }

    override func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let inset = ring ? lineWidth / 2 : 0
        shape.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func applyAnimations() {
        guard running, window != nil else {
            shape.removeAllAnimations()
            return
        }
        guard shape.animation(forKey: "breathing") == nil else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.4
        opacity.toValue = 1.0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.78
        scale.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = duration
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        shape.add(group, forKey: "breathing")
    }
}

/// 呼吸点的 SwiftUI 桥接。
struct OMBreathingDot: NSViewRepresentable {
    let color: Color
    let ring: Bool
    let lineWidth: CGFloat
    let duration: Double
    let running: Bool

    func makeNSView(context: Context) -> OMBreathingLayerView { OMBreathingLayerView(frame: .zero) }

    func updateNSView(_ view: OMBreathingLayerView, context: Context) {
        view.configure(color: color, ring: ring, lineWidth: lineWidth, duration: duration)
        view.running = running
    }
}

// MARK: - 转圈

/// 加载转圈:72% 弧线匀速顺时针旋转;停止时静止显示弧线。
@MainActor
final class OMSpinnerLayerView: OMLoopLayerView {
    private let arc = CAShapeLayer()
    private var lineWidth: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(color: Color, lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        arc.strokeColor = Self.cgColor(color)
        arc.lineWidth = lineWidth
        layoutLayers()
    }

    override func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let radius = max(min(bounds.width, bounds.height) / 2 - lineWidth / 2 - 1, 0)
        let path = CGMutablePath()
        // 从 3 点钟方向起,顺时针一整圈(strokeEnd 截取 72%)
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
        arc.path = path
        CATransaction.commit()
    }

    override func applyAnimations() {
        guard running, window != nil else {
            arc.removeAllAnimations()
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

/// 转圈的 SwiftUI 桥接。
struct OMSpinnerArc: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    let running: Bool

    func makeNSView(context: Context) -> OMSpinnerLayerView { OMSpinnerLayerView(frame: .zero) }

    func updateNSView(_ view: OMSpinnerLayerView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth)
        view.running = running
    }
}

// MARK: - 流光

/// 流光高亮带:一条两端透明的渐变带循环扫过;停止时移出可视区。
@MainActor
final class OMFlowBandLayerView: OMLoopLayerView {
    private let band = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.masksToBounds = true
        layer?.addSublayer(band)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 多色模式(流光溢彩)下带宽更大、扫动更慢,让色彩有展开的空间。
    private var multicolor = false

    func configure(color: Color, palette: [Color]) {
        if palette.count > 1 {
            let cgs = palette.map(Self.cgColor)
            let edge = cgs[0].copy(alpha: 0) ?? cgs[0]
            let tail = cgs[cgs.count - 1].copy(alpha: 0) ?? cgs[cgs.count - 1]
            band.colors = [edge] + cgs + [tail]
            band.locations = nil
        } else {
            let cg = Self.cgColor(color)
            band.colors = [cg.copy(alpha: 0) ?? cg, cg, cg.copy(alpha: 0) ?? cg]
        }
        let isMulti = palette.count > 1
        if isMulti != multicolor {
            multicolor = isMulti
            layoutLayers()
            if running { applyAnimations() }
        }
    }

    private var bandWidth: CGFloat { max(bounds.width * (multicolor ? 0.9 : 0.45), multicolor ? 56 : 28) }

    override func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: bandWidth, height: bounds.height)
        band.position = CGPoint(x: -bandWidth / 2, y: bounds.midY)
        CATransaction.commit()
    }

    override func applyAnimations() {
        guard running, window != nil, bounds.width > 0 else {
            band.removeAllAnimations()
            return
        }
        // 尺寸变化后需按新宽度重建
        band.removeAnimation(forKey: "flow")
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bandWidth / 2
        sweep.toValue = bounds.width + bandWidth / 2
        sweep.duration = multicolor ? 3.2 : 2.4
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "flow")
    }
}

/// 流光高亮带的 SwiftUI 桥接。
struct OMFlowBand: NSViewRepresentable {
    let color: Color
    /// 多色调色板(≥2 色时为流光溢彩,否则用 `color` 单色)。
    let palette: [Color]
    let running: Bool

    func makeNSView(context: Context) -> OMFlowBandLayerView { OMFlowBandLayerView(frame: .zero) }

    func updateNSView(_ view: OMFlowBandLayerView, context: Context) {
        view.configure(color: color, palette: palette)
        view.running = running
    }
}

extension View {
    /// 文字流光:在内容之上叠一条循环扫过的高亮带,并用内容自身作遮罩(只照亮笔画)。
    /// - Parameter color: 高亮带颜色(经典样式);流光溢彩样式改用主题强调色等组成的多色渐变
    public func omFlowOverlay(color: Color) -> some View {
        let aurora = AppearanceModel.shared.flowStyle == .aurora
        let palette: [Color] = aurora
            ? [OMColors.accent, OMColors.accent2, OMColors.success, OMColors.warning, OMColors.accent]
            : []
        return overlay {
            OMLoopGated { running in OMFlowBand(color: color, palette: palette, running: running) }
                .mask(self)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 字符帧循环(等待指示的「✻ ✽ …」)

/// 字符帧循环:把每个字符帧预渲染成位图,用离散关键帧动画切换 `contents`,不再每 0.15 秒让 SwiftUI 重算视图。
@MainActor
final class OMGlyphLayerView: OMLoopLayerView {
    private let content = CALayer()
    private var images: [CGImage] = []
    private var interval: Double = 0.15
    private var renderKey = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        content.contentsGravity = .center
        layer?.addSublayer(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 更新帧集合;`key` 不变时不重复渲染。
    func configure(key: String, interval: Double, scale: CGFloat, make: () -> [CGImage]) {
        self.interval = interval
        content.contentsScale = scale
        guard key != renderKey else { return }
        renderKey = key
        images = make()
        content.removeAllAnimations()
        content.contents = images.first
        if running { applyAnimations() }
    }

    override func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        CATransaction.commit()
    }

    override func applyAnimations() {
        guard running, window != nil, images.count > 1 else {
            content.removeAllAnimations()
            content.contents = images.first
            return
        }
        guard content.animation(forKey: "glyphs") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.duration = interval * Double(images.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        content.add(animation, forKey: "glyphs")
    }
}

/// 字符帧循环的 SwiftUI 桥接。
private struct OMGlyphCycleRepresentable: NSViewRepresentable {
    let frames: [String]
    let font: Font
    let color: Color
    let interval: Double
    let size: CGSize
    let running: Bool

    func makeNSView(context: Context) -> OMGlyphLayerView { OMGlyphLayerView(frame: .zero) }

    func updateNSView(_ view: OMGlyphLayerView, context: Context) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let rgba = NSColor(color).usingColorSpace(.sRGB).map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } ?? []
        let key = "\(frames.joined(separator: "|"))#\(rgba)#\(scale)#\(size.width)x\(size.height)#\(font)"
        view.configure(key: key, interval: interval, scale: scale) {
            frames.compactMap { glyph in
                let renderer = ImageRenderer(content: Text(glyph).font(font).foregroundStyle(color).frame(width: size.width, height: size.height))
                renderer.scale = scale
                return renderer.cgImage
            }
        }
        view.running = running
    }
}

/// 循环切换的字符帧;门控不放行(后台标签/减弱动态/需要静止)时显示静态的 `resting`。
public struct OMGlyphCycle: View {
    private let frames: [String]
    private let resting: String
    private let font: Font
    private let color: Color
    private let interval: Double
    private let animated: Bool

    /// - Parameters:
    ///   - frames: 动画字符帧
    ///   - resting: 静止时显示的字符
    ///   - font: 字体(取 `OMFonts` 令牌)
    ///   - color: 颜色(取 `OMColors` 令牌)
    ///   - interval: 每帧停留秒数
    ///   - animated: 为 false 时强制静止
    public init(frames: [String], resting: String, font: Font, color: Color, interval: Double = 0.15, animated: Bool = true) {
        self.frames = frames
        self.resting = resting
        self.font = font
        self.color = color
        self.interval = interval
        self.animated = animated
    }

    public var body: some View {
        let size = CGSize(width: 16, height: 20)
        OMLoopGated { running in
            if running && animated && frames.count > 1 {
                OMGlyphCycleRepresentable(frames: frames, font: font, color: color, interval: interval, size: size, running: true)
            } else {
                Text(resting).font(font).foregroundStyle(color)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
