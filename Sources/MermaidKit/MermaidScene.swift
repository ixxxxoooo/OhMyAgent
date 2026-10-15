// @author ygw
// Mermaid 绘制场景:布局阶段的输出,与具体渲染器解耦(SwiftUI Canvas、PNG 导出、测试断言共用)。

import CoreGraphics
import Foundation

/// 语义颜色:由渲染器按深浅色映射为真实颜色。
public enum MColor: Hashable, Sendable {
    case text, subtleText, nodeFill, nodeStroke, edge, groupFill, groupStroke, noteFill, activation
    case success, danger, warning
    /// 调色板第 n 色(循环使用)
    case accent(Int)
}

/// 节点形状。
public enum MShape: String, Sendable {
    case rect, rounded, stadium, subroutine, cylinder, circle, doubleCircle, diamond, hexagon, asymmetric, parallelogram, trapezoid
    /// 状态图起点(实心圆)
    case startDot
    /// 状态图终点(同心圆)
    case endDot
    /// 类图三栏框
    case classBox
}

/// 线型。
public enum MLineStyle: Sendable { case solid, dashed, thick }

/// 箭头/端点样式。
public enum MArrow: Sendable { case none, arrow, circle, cross, triangleHollow, diamondFilled, diamondHollow }

/// 文本锚点。
public enum MAnchor: Sendable { case leading, center, trailing }

/// 绘制项。
public enum MItem: Sendable {
    /// 带文字的节点形状
    case shape(MShape, rect: CGRect, text: String, fill: MColor, stroke: MColor)
    /// 折线(可平滑圆角),两端可带箭头
    case path(points: [CGPoint], style: MLineStyle, start: MArrow, end: MArrow, color: MColor)
    /// 文本;`background` 为 true 时底衬画布色(用于边标签)
    case text(String, at: CGPoint, anchor: MAnchor, size: Double, bold: Bool, color: MColor, background: Bool)
    /// 矩形(分组框、激活条、便签、甘特条)
    case rect(CGRect, fill: MColor?, stroke: MColor?, radius: Double, dashed: Bool)
    /// 饼图扇区(角度为弧度,自 12 点钟方向顺时针)
    case slice(center: CGPoint, radius: Double, from: Double, to: Double, color: MColor)
    /// 直线
    case line(CGPoint, CGPoint, style: MLineStyle, color: MColor)
    /// 圆点
    case dot(center: CGPoint, radius: Double, fill: MColor?, stroke: MColor?)
    /// 类图三栏内容:名称、成员、方法
    case classCompartments(rect: CGRect, title: String, fields: [String], methods: [String])
}

/// 一幅图的完整绘制描述。
public struct MScene: Sendable {
    public var size: CGSize
    public var items: [MItem]
    /// 节点矩形(按节点 ID),供测试做重叠断言与外部定位
    public var nodeRects: [String: CGRect]

    public init(size: CGSize, items: [MItem], nodeRects: [String: CGRect] = [:]) {
        self.size = size
        self.items = items
        self.nodeRects = nodeRects
    }
}

/// 解析或布局错误,带行号(1 起,未知为 0)。
public struct MermaidError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public init(line: Int = 0, _ message: String) {
        self.line = line
        self.message = message
    }
    public var description: String { line > 0 ? "第 \(line) 行:\(message)" : message }
}

/// 文本度量:不依赖 AppKit 的近似估算(CJK 宽 1em,拉丁字母约 0.56em),保证布局确定、可测试。
public enum MermaidMetrics {
    /// 估算单行文本宽度。
    public static func width(_ text: String, size: Double) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF, 0x3000...0x303F: total += 1.0
            case 0x20: total += 0.30
            case 0x69, 0x6C, 0x49, 0x2E, 0x2C, 0x3A, 0x3B, 0x27, 0x7C, 0x21, 0x28, 0x29, 0x5B, 0x5D, 0x74, 0x66, 0x6A, 0x72: total += 0.34
            case 0x6D, 0x77, 0x4D, 0x57, 0x40: total += 0.86
            default: total += 0.58
            }
        }
        return total * size
    }

    /// 把 `<br/>` 与字面 `\n` 规整为换行并拆行。
    public static func lines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 多行文本的包围尺寸。
    public static func size(_ text: String, fontSize: Double, lineSpacing: Double = 1.3) -> CGSize {
        let parts = lines(text)
        let w = parts.map { width($0, size: fontSize) }.max() ?? 0
        return CGSize(width: w, height: Double(parts.count) * fontSize * lineSpacing)
    }
}
