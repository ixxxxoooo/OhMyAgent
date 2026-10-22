// @author ixxxxoooo
// 融合模式的外框换算:Agent 窗口与 IDE 窗口互切时,目标窗口沿用来源窗口的外框,
// 视觉上就是「同一个窗口原地换了模式」。纯函数,便于单测。

import CoreGraphics

/// 融合模式切换时的外框换算。
public enum FusionFrame {
    /// 目标窗口应采用的外框。
    /// - Parameters:
    ///   - source: 来源窗口外框
    ///   - minSize: 目标窗口的最小尺寸(来源比它小时放大到最小尺寸,左上角保持不动)
    ///   - screens: 各屏幕的可见区域
    /// - Returns: 采用的外框;来源外框无效(为空、非有限数、完全落在屏幕之外)时为 nil,调用方保持目标窗口原外框
    public static func adopted(_ source: CGRect, minSize: CGSize, screens: [CGRect]) -> CGRect? {
        guard !source.isNull, !source.isInfinite, source.width > 0, source.height > 0,
              source.origin.x.isFinite, source.origin.y.isFinite,
              screens.contains(where: { $0.intersects(source) }) else { return nil }
        let width = max(source.width, minSize.width)
        let height = max(source.height, minSize.height)
        // AppKit 坐标系原点在左下:放大时保持窗口顶边不动
        return CGRect(x: source.minX, y: source.maxY - height, width: width, height: height)
    }
}
