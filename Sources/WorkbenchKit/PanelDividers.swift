// @author ixxxxoooo
// 侧栏尺寸:范围、默认值与拖动分隔条时的宽度换算(纯函数,便于测试)。

import Foundation

/// 侧栏所属一侧。
public enum PanelSide: Equatable, Sendable {
    case left, right
}

/// 面板尺寸范围与默认值(对齐 kuku:左栏 180–520,右栏 240–800)。
public enum PanelMetrics {
    public static let leftRange: ClosedRange<Double> = 180...520
    public static let rightRange: ClosedRange<Double> = 240...800
    public static let leftDefault: Double = 260
    public static let rightDefault: Double = 340

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
}
