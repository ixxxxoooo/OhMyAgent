// @author ixxxxoooo
// 侧栏尺寸:范围、默认值与拖动分隔条时的宽度换算(纯函数,便于测试)。

import Foundation

/// 侧栏所属一侧。
public enum PanelSide: String, Codable, Equatable, Sendable {
    case left, right
}

/// 面板尺寸范围与默认值(对齐 kuku:左栏 200–520(须容纳顶部浮层的 198pt);右栏下限 240,上限随窗口宽度动态计算,见 `rightMax`)。
public enum PanelMetrics {
    public static let leftRange: ClosedRange<Double> = 200...520
    /// 右栏宽度的静态范围:下限 240;上限仅作持久化的兜底(10000),实际可拖到多宽取决于窗口(`rightMax`)。
    public static let rightRange: ClosedRange<Double> = 240...10_000
    /// 右栏拖宽时中栏至少保留的宽度
    public static let centerMinimum: Double = 320
    public static let leftDefault: Double = 260
    public static let rightDefault: Double = 340
    /// 右栏当前窗口下允许的最大宽度:窗口宽度减去(可见的)项目栏宽度与中栏最小宽度,且不小于下限。
    /// - Parameters:
    ///   - window: 窗口(工作区)宽度
    ///   - sidebar: 项目栏占用的宽度(收起时为 0)
    /// - Returns: 右栏最大宽度
    public static func rightMax(window: Double, sidebar: Double) -> Double {
        max(rightRange.lowerBound, window - sidebar - centerMinimum)
    }
    /// 终端面板内右侧「终端列表」的宽度范围与默认值
    public static let terminalListRange: ClosedRange<Double> = 120...320
    public static let terminalListDefault: Double = 180

    /// 某一侧栏允许的宽度范围。
    public static func range(for side: PanelSide) -> ClosedRange<Double> {
        side == .left ? leftRange : rightRange
    }

    /// 某一侧栏的默认宽度。
    public static func defaultWidth(for side: PanelSide) -> Double {
        side == .left ? leftDefault : rightDefault
    }

    /// 把宽度限制在允许范围内。
    /// - Parameters:
    ///   - width: 期望宽度
    ///   - side: 侧栏
    /// - Returns: 限制后的宽度
    public static func clamp(_ width: Double, side: PanelSide) -> Double {
        let range = range(for: side)
        return min(max(width, range.lowerBound), range.upperBound)
    }

    /// 拖动分隔条后的新宽度:左栏向右拖变宽,右栏向左拖变宽。
    /// - Parameters:
    ///   - base: 开始拖动时的宽度
    ///   - translation: 水平位移(向右为正)
    ///   - side: 侧栏
    /// - Returns: 限制后的新宽度
    public static func resized(base: Double, translation: Double, side: PanelSide) -> Double {
        clamp(side == .left ? base + translation : base - translation, side: side)
    }

    /// 通用的分隔条宽度换算:列在左侧时向右拖变宽,在右侧时向左拖变宽,结果限制在 `range` 内。
    /// - Parameters:
    ///   - base: 开始拖动时的宽度
    ///   - translation: 水平位移(向右为正)
    ///   - side: 该列所在的物理一侧
    ///   - range: 允许的宽度范围
    /// - Returns: 限制后的新宽度
    public static func resized(base: Double, translation: Double, side: PanelSide, range: ClosedRange<Double>) -> Double {
        let raw = side == .left ? base + translation : base - translation
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}
