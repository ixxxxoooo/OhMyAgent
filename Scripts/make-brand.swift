#!/usr/bin/env swift
// @author ixxxxoooo
// 生成品牌素材(方案 B「Oh 环 · 运行点」扁平版):标记 SVG(深/浅底)、菜单栏模板 SVG、
// README 横版 logo PNG(透明底,深/浅两套,@2x)。几何与 Scripts/make-icon.swift 一致。
// 用法: swift Scripts/make-brand.swift <输出目录>   (默认 Resources/Brand)

import AppKit
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Brand")
try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let paper = NSColor(srgbRed: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEC / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1B / 255, green: 0x1A / 255, blue: 0x19 / 255, alpha: 1)
let ember = NSColor(srgbRed: 0xF5 / 255, green: 0x4E / 255, blue: 0x00 / 255, alpha: 1)

// 1024 设计网格上的字形参数(y 轴向下,用于 SVG)
let ringRadius = 230.0, ringWidth = 92.0, dotRadius = 72.0
/// 标记裁切框:字形外接正方形 232...792
let markOrigin = 232.0, markSize = 560.0

/// 极坐标点(SVG 坐标,y 向下)。
/// - Parameter degrees: 角度
/// - Returns: (x, y)
func point(_ degrees: Double) -> (Double, Double) {
    let a = degrees * .pi / 180
    return (512 + ringRadius * cos(a), 512 + ringRadius * sin(a))
}

/// 生成标记 SVG。
/// - Parameters:
///   - ringColor: 圆环颜色
///   - dotColor: 运行点颜色
/// - Returns: SVG 文本
func markSVG(ringColor: String, dotColor: String) -> String {
    let (x0, y0) = point(-2), (x1, y1) = point(282), (dx, dy) = point(-40)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(Int(markOrigin)) \(Int(markOrigin)) \(Int(markSize)) \(Int(markSize))">\
    <path d="M\(String(format: "%.1f %.1f", x0, y0)) A\(Int(ringRadius)) \(Int(ringRadius)) 0 1 1 \(String(format: "%.1f %.1f", x1, y1))" \
    fill="none" stroke="\(ringColor)" stroke-width="\(Int(ringWidth))" stroke-linecap="round"/>\
    <circle cx="\(String(format: "%.1f", dx))" cy="\(String(format: "%.1f", dy))" r="\(Int(dotRadius))" fill="\(dotColor)"/></svg>

    """
}

/// 在当前图形上下文绘制扁平标记(AppKit 坐标,y 向上)。
/// - Parameters:
///   - rect: 标记所占正方形
///   - ringColor: 圆环颜色
func drawMark(in rect: NSRect, ringColor: NSColor) {
    let s = rect.width / markSize
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: ringRadius * s, startAngle: 2, endAngle: 78, clockwise: true)
    ring.lineWidth = ringWidth * s
    ring.lineCapStyle = .round
    ringColor.setStroke()
    ring.stroke()
    let a = 40 * Double.pi / 180
    let dot = NSPoint(x: center.x + ringRadius * s * cos(a), y: center.y + ringRadius * s * sin(a))
    let r = dotRadius * s
    ember.setFill()
    NSBezierPath(ovalIn: NSRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)).fill()
}

/// 渲染横版 logo(标记 + 「OhMyAgent」字标,透明底)。
/// - Parameters:
///   - textColor: 字标与圆环颜色
///   - name: 输出文件名
func renderLockup(textColor: NSColor, name: String) {
    let height = 240.0, pad = 40.0, markSide = 160.0, gap = 36.0
    let font = NSFont.systemFont(ofSize: 132, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: -3.0]
    let text = NSAttributedString(string: "OhMyAgent", attributes: attrs)
    let textSize = text.size()
    let width = Int((pad + markSide + gap + textSize.width + pad).rounded(.up))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: Int(height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawMark(in: NSRect(x: pad, y: (height - markSide) / 2, width: markSide, height: markSide), ringColor: textColor)
    // 以大写字高居中,而非整行高度
    let baseline = (height - font.capHeight) / 2
    text.draw(at: NSPoint(x: pad + markSide + gap, y: baseline + font.descender))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: outputDir.appendingPathComponent(name))
}

let svgs = [
    "mark-on-dark.svg": markSVG(ringColor: "#F3F1EC", dotColor: "#F54E00"),
    "mark-on-light.svg": markSVG(ringColor: "#1B1A19", dotColor: "#F54E00"),
    "menubar-template.svg": markSVG(ringColor: "#000000", dotColor: "#000000"),
]
for (name, text) in svgs {
    try! text.write(to: outputDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
renderLockup(textColor: paper, name: "logo-on-dark@2x.png")
renderLockup(textColor: ink, name: "logo-on-light@2x.png")
print("已生成 \(outputDir.path)")
