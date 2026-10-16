// @author ixxxxoooo
// 场景渲染:SwiftUI GraphicsContext 绘制(画布与 PNG 导出共用),支持深浅色。

import AppKit
import SwiftUI

/// 渲染配色(随外观变化)。
public struct MermaidPalette: Sendable {
    public var dark: Bool
    public var background: Color

    public init(dark: Bool, background: Color? = nil) {
        self.dark = dark
        self.background = background ?? (dark ? Color(red: 0.11, green: 0.115, blue: 0.13) : .white)
    }

    private func c(_ light: UInt32, _ darkValue: UInt32, _ alpha: Double = 1) -> Color {
        let v = dark ? darkValue : light
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255).opacity(alpha)
    }

    static let accents: [UInt32] = [0x6366F1, 0x22C55E, 0xF59E0B, 0xEF4444, 0x06B6D4, 0xA855F7, 0xEC4899, 0x84CC16]

    /// 语义色映射。
    public func color(_ role: MColor) -> Color {
        switch role {
        case .text: return c(0x1F2328, 0xE6E8EB)
        case .subtleText: return c(0x57606A, 0xA0A8B3)
        case .nodeFill: return c(0xF1F5F9, 0x2A2D35)
        case .nodeStroke: return c(0x94A3B8, 0x5B6372)
        case .edge: return c(0x64748B, 0x9AA4B2)
        case .groupFill: return c(0xF1F5F9, 0xFFFFFF, dark ? 0.04 : 0.55)
        case .groupStroke: return c(0xCBD5E1, 0x3A3F4B)
        case .noteFill: return c(0xFEF9C3, 0x4A4426)
        case .activation: return c(0xE2E8F0, 0x3B4150)
        case .success: return c(0x16A34A, 0x4ADE80)
        case .danger: return c(0xDC2626, 0xF87171)
        case .warning: return c(0xD97706, 0xFBBF24)
        case .accent(let n):
            let v = Self.accents[((n % Self.accents.count) + Self.accents.count) % Self.accents.count]
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255).opacity(dark ? 0.9 : 1)
        }
    }
}

public enum MermaidRenderer {
    /// 绘制整幅场景。
    public static func draw(_ scene: MScene, in ctx: inout GraphicsContext, palette: MermaidPalette) {
        for item in scene.items { draw(item, in: &ctx, palette: palette) }
    }

    private static func draw(_ item: MItem, in ctx: inout GraphicsContext, palette: MermaidPalette) {
        switch item {
        case let .shape(shape, rect, text, fill, stroke):
            drawShape(shape, rect: rect, text: text, fill: palette.color(fill), stroke: palette.color(stroke), in: &ctx, palette: palette)
        case let .path(points, style, start, end, color):
            drawPath(points, style: style, start: start, end: end, color: palette.color(color), in: &ctx, palette: palette)
        case let .text(text, at, anchor, size, bold, color, background):
            drawText(text, at: at, anchor: anchor, size: size, bold: bold, color: palette.color(color), background: background ? palette.background : nil, in: &ctx)
        case let .rect(rect, fill, stroke, radius, dashed):
            let path = Path(roundedRect: rect, cornerRadius: radius)
            if let fill { ctx.fill(path, with: .color(palette.color(fill))) }
            if let stroke {
                ctx.stroke(path, with: .color(palette.color(stroke)), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
        case let .slice(center, radius, from, to, color):
            var p = Path()
            p.move(to: center)
            p.addArc(center: center, radius: radius, startAngle: .radians(from - .pi / 2), endAngle: .radians(to - .pi / 2), clockwise: false)
            p.closeSubpath()
            ctx.fill(p, with: .color(palette.color(color)))
            ctx.stroke(p, with: .color(palette.background), lineWidth: 1.5)
        case let .line(a, b, style, color):
            var p = Path()
            p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(palette.color(color)), style: strokeStyle(style))
        case let .dot(center, radius, fill, stroke):
            let p = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            if let fill { ctx.fill(p, with: .color(palette.color(fill))) }
            if let stroke { ctx.stroke(p, with: .color(palette.color(stroke)), lineWidth: 1) }
        case let .classCompartments(rect, title, fields, methods):
            drawClass(rect: rect, title: title, fields: fields, methods: methods, in: &ctx, palette: palette)
        }
    }

    private static func strokeStyle(_ style: MLineStyle) -> StrokeStyle {
        switch style {
        case .solid: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        case .dashed: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [5, 4])
        case .thick: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
        }
    }

    // MARK: 文本

    private static func drawText(_ text: String, at p: CGPoint, anchor: MAnchor, size: Double, bold: Bool, color: Color, background: Color?, in ctx: inout GraphicsContext) {
        guard !text.isEmpty else { return }
        let lines = MermaidMetrics.lines(text)
        let lineHeight = size * 1.3
        let totalHeight = lineHeight * Double(lines.count)
        if let background {
            let w = (lines.map { MermaidMetrics.width($0, size: size) }.max() ?? 0) + 10
            let x: Double = anchor == .center ? p.x - w / 2 : (anchor == .leading ? p.x - 5 : p.x - w + 5)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: p.y - totalHeight / 2 - 1, width: w, height: totalHeight + 2), cornerRadius: 3), with: .color(background.opacity(0.92)))
        }
        for (i, line) in lines.enumerated() {
            let y = p.y - totalHeight / 2 + lineHeight * (Double(i) + 0.5)
            let t = Text(line).font(.system(size: size, weight: bold ? .semibold : .regular)).foregroundColor(color)
            let unit: UnitPoint = anchor == .center ? .center : (anchor == .leading ? .leading : .trailing)
            ctx.draw(t, at: CGPoint(x: p.x, y: y), anchor: unit)
        }
    }

    // MARK: 形状

    private static func drawShape(_ shape: MShape, rect r: CGRect, text: String, fill: Color, stroke: Color, in ctx: inout GraphicsContext, palette: MermaidPalette) {
        let line = StrokeStyle(lineWidth: 1.4, lineJoin: .round)
        switch shape {
        case .startDot:
            ctx.fill(Path(ellipseIn: r), with: .color(fill)); return
        case .endDot:
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 1, dy: 1)), with: .color(stroke), style: line)
            ctx.fill(Path(ellipseIn: r.insetBy(dx: 6, dy: 6)), with: .color(fill)); return
        default: break
        }
        let path = shapePath(shape, r)
        ctx.fill(path, with: .color(fill))
        ctx.stroke(path, with: .color(stroke), style: line)
        switch shape {
        case .subroutine:
            for dx in [8.0, r.width - 8] {
                var p = Path(); p.move(to: CGPoint(x: r.minX + dx, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + dx, y: r.maxY))
                ctx.stroke(p, with: .color(stroke), style: line)
            }
        case .doubleCircle:
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 5, dy: 5)), with: .color(stroke), style: line)
        case .cylinder:
            var p = Path()
            let ry = min(10.0, r.height / 6)
            p.addEllipse(in: CGRect(x: r.minX, y: r.minY + ry * 2 - ry * 2 + 0, width: r.width, height: ry * 2))
            ctx.stroke(p, with: .color(stroke), style: line)
        default: break
        }
        let center = CGPoint(x: r.midX, y: r.midY + (shape == .cylinder ? min(10.0, r.height / 6) : 0))
        drawText(text, at: center, anchor: .center, size: FlowLayout.fontSize, bold: false, color: palette.color(.text), background: nil, in: &ctx)
    }

    static func shapePath(_ shape: MShape, _ r: CGRect) -> Path {
        switch shape {
        case .rect, .subroutine, .classBox: return Path(roundedRect: r, cornerRadius: 2)
        case .rounded: return Path(roundedRect: r, cornerRadius: 9)
        case .stadium: return Path(roundedRect: r, cornerRadius: r.height / 2)
        case .circle, .doubleCircle, .startDot, .endDot: return Path(ellipseIn: r)
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
            return p
        case .hexagon:
            let k = min(18.0, r.width / 4)
            var p = Path()
            p.move(to: CGPoint(x: r.minX + k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
            return p
        case .asymmetric:
            let k = min(16.0, r.width / 4)
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + k, y: r.midY)); p.closeSubpath()
            return p
        case .parallelogram:
            let k = min(14.0, r.width / 5)
            var p = Path()
            p.move(to: CGPoint(x: r.minX + k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
            return p
        case .trapezoid:
            let k = min(14.0, r.width / 5)
            var p = Path()
            p.move(to: CGPoint(x: r.minX + k, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
            return p
        case .cylinder:
            let ry = min(10.0, r.height / 6)
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY + ry))
            p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + ry), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - ry))
            p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - ry), control: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    // MARK: 类框

    private static func drawClass(rect r: CGRect, title: String, fields: [String], methods: [String], in ctx: inout GraphicsContext, palette: MermaidPalette) {
        let box = Path(roundedRect: r, cornerRadius: 3)
        ctx.fill(box, with: .color(palette.color(.nodeFill)))
        let titleLines = MermaidMetrics.lines(title)
        let titleHeight = 28 + Double(titleLines.count - 1) * 14
        drawText(title, at: CGPoint(x: r.midX, y: r.minY + titleHeight / 2), anchor: .center, size: 13, bold: true, color: palette.color(.text), background: nil, in: &ctx)
        var y = r.minY + titleHeight
        let line = StrokeStyle(lineWidth: 1.2)
        func divider(_ yy: Double) {
            var p = Path(); p.move(to: CGPoint(x: r.minX, y: yy)); p.addLine(to: CGPoint(x: r.maxX, y: yy))
            ctx.stroke(p, with: .color(palette.color(.nodeStroke)), style: line)
        }
        divider(y)
        y += 5
        for f in fields {
            drawText(f, at: CGPoint(x: r.minX + 10, y: y + 9), anchor: .leading, size: 12, bold: false, color: palette.color(.text), background: nil, in: &ctx)
            y += 18
        }
        y += 5
        if !methods.isEmpty {
            divider(y)
            y += 5
            for m in methods {
                drawText(m, at: CGPoint(x: r.minX + 10, y: y + 9), anchor: .leading, size: 12, bold: false, color: palette.color(.text), background: nil, in: &ctx)
                y += 18
            }
        }
        ctx.stroke(box, with: .color(palette.color(.nodeStroke)), lineWidth: 1.4)
    }

    // MARK: 折线与箭头

    private static func drawPath(_ pts: [CGPoint], style: MLineStyle, start: MArrow, end: MArrow, color: Color, in ctx: inout GraphicsContext, palette: MermaidPalette) {
        guard pts.count >= 2 else { return }
        var points = pts
        // 箭头占位:线段末端回缩,避免线条穿过空心头
        func inset(_ index: Int, _ neighbor: Int, _ amount: Double) {
            let dx = points[neighbor].x - points[index].x, dy = points[neighbor].y - points[index].y
            let len = hypot(dx, dy)
            guard len > amount * 1.5 else { return }
            points[index] = CGPoint(x: points[index].x + dx / len * amount, y: points[index].y + dy / len * amount)
        }
        let startInset = headLength(start), endInset = headLength(end)
        let original = pts
        if startInset > 0 { inset(0, 1, startInset * 0.6) }
        if endInset > 0 { inset(points.count - 1, points.count - 2, endInset * 0.6) }

        var path = Path()
        path.move(to: points[0])
        if points.count == 2 { path.addLine(to: points[1]) }
        else {
            for k in 1..<(points.count - 1) {
                let prev = points[k - 1], cur = points[k], next = points[k + 1]
                let r = min(12.0, hypot(cur.x - prev.x, cur.y - prev.y) / 2, hypot(next.x - cur.x, next.y - cur.y) / 2)
                let a = toward(cur, prev, r), b = toward(cur, next, r)
                path.addLine(to: a)
                path.addQuadCurve(to: b, control: cur)
            }
            path.addLine(to: points[points.count - 1])
        }
        ctx.stroke(path, with: .color(color), style: strokeStyle(style))
        drawHead(end, tip: original[original.count - 1], from: original[original.count - 2], color: color, in: &ctx, palette: palette)
        drawHead(start, tip: original[0], from: original[1], color: color, in: &ctx, palette: palette)
    }

    private static func headLength(_ a: MArrow) -> Double {
        switch a { case .none: 0; case .arrow: 9; case .circle: 9; case .cross: 8; case .triangleHollow: 13; case .diamondFilled, .diamondHollow: 16 }
    }

    private static func toward(_ p: CGPoint, _ q: CGPoint, _ d: Double) -> CGPoint {
        let len = hypot(q.x - p.x, q.y - p.y)
        guard len > 0 else { return p }
        return CGPoint(x: p.x + (q.x - p.x) / len * d, y: p.y + (q.y - p.y) / len * d)
    }

    private static func drawHead(_ kind: MArrow, tip: CGPoint, from: CGPoint, color: Color, in ctx: inout GraphicsContext, palette: MermaidPalette) {
        guard kind != .none else { return }
        let len = hypot(tip.x - from.x, tip.y - from.y)
        guard len > 0 else { return }
        let ux = (tip.x - from.x) / len, uy = (tip.y - from.y) / len
        let nx = -uy, ny = ux
        func pt(_ back: Double, _ side: Double) -> CGPoint { CGPoint(x: tip.x - ux * back + nx * side, y: tip.y - uy * back + ny * side) }
        var p = Path()
        switch kind {
        case .arrow:
            p.move(to: tip); p.addLine(to: pt(10, 4.5)); p.addLine(to: pt(10, -4.5)); p.closeSubpath()
            ctx.fill(p, with: .color(color))
        case .triangleHollow:
            p.move(to: tip); p.addLine(to: pt(13, 6)); p.addLine(to: pt(13, -6)); p.closeSubpath()
            ctx.fill(p, with: .color(palette.background)); ctx.stroke(p, with: .color(color), lineWidth: 1.3)
        case .diamondFilled, .diamondHollow:
            p.move(to: tip); p.addLine(to: pt(8, 5)); p.addLine(to: pt(16, 0)); p.addLine(to: pt(8, -5)); p.closeSubpath()
            ctx.fill(p, with: .color(kind == .diamondFilled ? color : palette.background)); ctx.stroke(p, with: .color(color), lineWidth: 1.3)
        case .circle:
            let c = pt(5, 0)
            p.addEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            ctx.fill(p, with: .color(palette.background)); ctx.stroke(p, with: .color(color), lineWidth: 1.4)
        case .cross:
            let c = pt(5, 0)
            p.move(to: CGPoint(x: c.x - 4, y: c.y - 4)); p.addLine(to: CGPoint(x: c.x + 4, y: c.y + 4))
            p.move(to: CGPoint(x: c.x + 4, y: c.y - 4)); p.addLine(to: CGPoint(x: c.x - 4, y: c.y + 4))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        case .none: break
        }
    }

    // MARK: 导出

    /// 渲染为 PNG 数据。
    /// - Parameters:
    ///   - scene: 场景
    ///   - dark: 是否深色
    ///   - scale: 像素倍率(默认 2)
    @MainActor
    public static func pngData(_ scene: MScene, dark: Bool, scale: Double = 2) -> Data? {
        let palette = MermaidPalette(dark: dark)
        let content = Canvas { ctx, _ in
            var c = ctx
            draw(scene, in: &c, palette: palette)
        }
        .frame(width: max(scene.size.width, 1), height: max(scene.size.height, 1))
        .background(palette.background)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// 把场景绘制为 SwiftUI 视图;当可用宽度小于场景宽度时等比缩小。
public struct MermaidCanvas: View {
    public let scene: MScene
    public var fitWidth: Bool
    @Environment(\.colorScheme) private var scheme

    public init(scene: MScene, fitWidth: Bool = true) {
        self.scene = scene
        self.fitWidth = fitWidth
    }

    public var body: some View {
        let palette = MermaidPalette(dark: scheme == .dark, background: .clear)
        if fitWidth {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / max(scene.size.width, 1))
                canvas(palette: palette)
                    .frame(width: scene.size.width, height: scene.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: scene.size.width * scale, height: scene.size.height * scale, alignment: .topLeading)
            }
            .aspectRatio(scene.size.width / max(scene.size.height, 1), contentMode: .fit)
            .frame(maxWidth: scene.size.width)
        } else {
            canvas(palette: palette).frame(width: scene.size.width, height: scene.size.height)
        }
    }

    private func canvas(palette: MermaidPalette) -> some View {
        Canvas { ctx, _ in
            var c = ctx
            let paletteWithBG = MermaidPalette(dark: palette.dark, background: palette.dark ? Color(red: 0.11, green: 0.115, blue: 0.13) : .white)
            MermaidRenderer.draw(scene, in: &c, palette: paletteWithBG)
        }
    }
}
