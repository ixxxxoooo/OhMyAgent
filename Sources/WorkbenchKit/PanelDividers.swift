// @author ygw
// 侧栏分隔条几何:判断双击落在哪条分隔条上、属于左栏还是右栏(纯函数,便于测试)。

import Foundation

/// 面板尺寸范围与默认值(对齐 kuku:左栏 180–520,右栏 240–800)。
public enum PanelMetrics {
    public static let leftRange: ClosedRange<Double> = 180...520
    public static let rightRange: ClosedRange<Double> = 240...800
    public static let leftDefault: Double = 260
    public static let rightDefault: Double = 340
}

/// 分隔条所属的侧栏。
public enum PanelSide: Equatable, Sendable {
    case left, right
}

/// 一列(split view 的一个 arranged subview)的水平范围。
public struct PanelColumn: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    /// 已折叠/隐藏(宽度为 0 或被标记隐藏)
    public var hidden: Bool

    public init(minX: Double, maxX: Double, hidden: Bool) {
        self.minX = minX
        self.maxX = maxX
        self.hidden = hidden
    }
}

/// 分隔条命中判断。
public enum PanelDividers {
    /// 判断横坐标 `x` 是否命中某条分隔条,返回它属于哪个侧栏。
    ///
    /// 列顺序固定为「[左栏] 中栏 [右栏]」;隐藏的列不参与。
    /// - Parameters:
    ///   - x: 点击点的横坐标(与列同一坐标系)
    ///   - columns: 从左到右的各列(2 或 3 列)
    ///   - leftVisible: 左栏是否显示(仅两列时用于判别)
    ///   - rightVisible: 右栏是否显示(仅两列时用于判别)
    ///   - tolerance: 命中容差(分隔条两侧各扩展的点数)
    /// - Returns: 命中的侧栏;未命中返回 nil
    public static func side(
        at x: Double,
        columns: [PanelColumn],
        leftVisible: Bool,
        rightVisible: Bool,
        tolerance: Double = 5
    ) -> PanelSide? {
        guard columns.count >= 2 else { return nil }
        let visible = columns.enumerated().filter { !$0.element.hidden && $0.element.maxX - $0.element.minX > 0 }
        guard visible.count >= 2 else { return nil }
        for pair in zip(visible, visible.dropFirst()) {
            guard x >= pair.0.element.maxX - tolerance, x <= pair.1.element.minX + tolerance else { continue }
            if columns.count == 3 { return pair.0.offset == 0 ? .left : .right }
            if leftVisible && !rightVisible { return .left }
            if rightVisible && !leftVisible { return .right }
            return nil
        }
        return nil
    }
}
