// @author ixxxxoooo
// 图表视口(纯逻辑):缩放比例 + 平移,用于悬浮预览里的拖动/缩放/适应窗口。
// 坐标约定:视口左上角为原点;`offset` 是场景原点(0,0)在视口中的位置;屏幕点 = 场景点 × scale + offset。

import CoreGraphics
import Foundation

/// 图表视口状态。
public struct MermaidViewport: Equatable, Sendable {
    /// 允许的缩放范围
    public static let minScale: Double = 0.1
    public static let maxScale: Double = 8

    /// 缩放比例(1 = 实际大小)
    public private(set) var scale: Double
    /// 场景原点在视口中的位置
    public private(set) var offset: CGPoint

    public init(scale: Double = 1, offset: CGPoint = .zero) {
        self.scale = Self.clamp(scale)
        self.offset = offset
    }

    /// 把缩放比例限制在合法范围内(非有限值回到 1)。
    /// - Parameter value: 期望比例
    /// - Returns: 合法比例
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, minScale), maxScale)
    }

    /// 适应窗口:整图缩放到刚好放进视口(留边距),居中;默认最多放大到 `maxFit` 倍。
    /// - Parameters:
    ///   - scene: 场景尺寸
    ///   - viewport: 视口尺寸
    ///   - padding: 四周留白
    ///   - maxFit: 适应时的最大放大倍数(小图不要放得过大)
    public mutating func fit(scene: CGSize, in viewport: CGSize, padding: CGFloat = 24, maxFit: Double = 2) {
        guard scene.width > 0, scene.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let availableW = max(viewport.width - padding * 2, 1)
        let availableH = max(viewport.height - padding * 2, 1)
        let fitted = min(availableW / scene.width, availableH / scene.height, maxFit)
        scale = Self.clamp(fitted)
        center(scene: scene, in: viewport)
    }

    /// 以实际大小(100%)显示并居中。
    public mutating func actualSize(scene: CGSize, in viewport: CGSize) {
        scale = 1
        center(scene: scene, in: viewport)
    }

    /// 在当前缩放下把场景居中。
    public mutating func center(scene: CGSize, in viewport: CGSize) {
        offset = CGPoint(x: (viewport.width - scene.width * scale) / 2, y: (viewport.height - scene.height * scale) / 2)
    }

    /// 平移。
    /// - Parameter delta: 视口坐标系下的位移
    public mutating func pan(by delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
    }

    /// 以视口内某点为锚点缩放(锚点下的场景位置保持不动)。
    /// - Parameters:
    ///   - factor: 乘数(>1 放大)
    ///   - anchor: 视口坐标系下的锚点
    public mutating func zoom(by factor: Double, anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let next = Self.clamp(scale * factor)
        guard next != scale else { return }
        let ratio = next / scale
        offset = CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio, y: anchor.y - (anchor.y - offset.y) * ratio)
        scale = next
    }

    /// 缩放到指定比例(以视口中心为锚点)。
    public mutating func setScale(_ value: Double, in viewport: CGSize) {
        zoom(by: Self.clamp(value) / scale, anchor: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
    }

    /// 视口坐标 → 场景坐标。
    public func scenePoint(fromViewport point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// 缩放百分比文本(取整)。
    public var percentText: String { "\(Int((scale * 100).rounded()))%" }
}
