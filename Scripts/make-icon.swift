#!/usr/bin/env swift
// @author ixxxxoooo
// 程序化绘制 OhMyAgent 应用图标(方案 B「Oh 环 · 运行点」,深墨底 + Liquid Glass 质感):
// 1024 画布,824 超椭圆主体 + 柔和投影;纸白玻璃开口圆环 + Ember 玻璃运行点。
// 输出 AppIcon.iconset 全部尺寸并交给 iconutil 生成 icns。
// 用法: swift Scripts/make-icon.swift <输出目录>   (默认 build/icon)

import AppKit
import CoreGraphics
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// 十六进制 sRGB 颜色。
/// - Parameters:
///   - hex: 形如 0xF54E00 的颜色值
///   - alpha: 不透明度
/// - Returns: CGColor
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// 由颜色与位置构造线性/径向渐变。
/// - Parameter stops: (颜色, 位置) 列表
/// - Returns: CGGradient
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

/// 超椭圆(squircle)路径:|x/a|^n + |y/a|^n = 1,n≈4.4 更接近 macOS 图标的连续曲率圆角。
/// - Parameters:
///   - rect: 外接矩形
///   - n: 指数
/// - Returns: 闭合路径
func squirclePath(rect: CGRect, exponent n: CGFloat = 4.4) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 角度转弧度。
func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

// MARK: - 字形几何(y 轴向上,与设计稿 SVG 镜像)

let center = CGPoint(x: 512, y: 512)
let ringRadius: CGFloat = 230
let ringWidth: CGFloat = 92
let dotRadius: CGFloat = 72
/// 运行点在右上 40°,圆环从 2° 顺时针绕到 78°,缺口留给运行点。
let dotCenter = CGPoint(x: center.x + ringRadius * cos(rad(40)), y: center.y + ringRadius * sin(rad(40)))

/// 开口圆环的中心线路径。
func ringArc() -> CGPath {
    let p = CGMutablePath()
    p.addArc(center: center, radius: ringRadius, startAngle: rad(2), endAngle: rad(78), clockwise: true)
    return p
}

/// 圆环描边后的填充轮廓。
/// - Parameter width: 描边宽度
func ringOutline(width: CGFloat) -> CGPath {
    ringArc().copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// 运行点圆形路径。
func dotPath() -> CGPath {
    CGPath(ellipseIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2), transform: nil)
}

/// 在路径内绘制自上而下的线性渐变。
/// - Parameters:
///   - ctx: 绘图上下文
///   - path: 裁剪路径
///   - g: 渐变
///   - top: 渐变起点 y(上)
///   - bottom: 渐变终点 y(下)
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// 只绘制路径的投影(本体画到画布外,投影偏移回来),避免半透明玻璃透出底色。
/// - Parameters:
///   - ctx: 绘图上下文
///   - path: 投影形状
///   - offsetY: 投影纵向偏移(向下为负)
///   - blur: 模糊半径
///   - color: 投影颜色
func shadowOnly(_ ctx: CGContext, _ path: CGPath, offsetY: CGFloat, blur: CGFloat, color: CGColor) {
    let away: CGFloat = 4000
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -away * ctx.ctm.a, height: offsetY * ctx.ctm.d), blur: blur * ctx.ctm.a, color: color)
    ctx.translateBy(x: away, y: 0)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}

/// 渲染指定像素尺寸的图标。
/// - Parameter pixels: 输出边长(像素)
/// - Returns: 图像
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(rect: body)

    // 1. 图标投影
    shadowOnly(ctx, shape, offsetY: -14, blur: 30, color: rgb(0x000000, 0.42))

    // 2. 深墨主体:上暖灰 → 下近黑,顶部柔光
    fill(ctx, shape, gradient([(rgb(0x34312E), 0), (rgb(0x1E1C1B), 0.55), (rgb(0x121111), 1)]), top: body.maxY, bottom: body.minY)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(rgb(0xFFFFFF, 0.10), 0), (rgb(0xFFFFFF, 0), 1)]),
                           startCenter: CGPoint(x: 512, y: 724), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 724), endRadius: 520, options: [])

    // 3. 运行点的 Ember 辉光与字形落影
    shadowOnly(ctx, dotPath(), offsetY: 0, blur: 90, color: rgb(0xF54E00, 0.65))
    let glyph = CGMutablePath()
    glyph.addPath(ringOutline(width: ringWidth))
    glyph.addPath(dotPath())
    shadowOnly(ctx, glyph, offsetY: -26, blur: 48, color: rgb(0x000000, 0.5))

    // 4. 玻璃圆环与 Ember 玻璃运行点
    fill(ctx, ringOutline(width: ringWidth), gradient([(rgb(0xFFFFFF, 0.95), 0), (rgb(0xE9E4DC, 0.62), 1)]), top: 764, bottom: 244)
    fill(ctx, dotPath(), gradient([(rgb(0xFF9A5C), 0), (rgb(0xF65A10), 0.5), (rgb(0xD93E00), 1)]), top: 764, bottom: 244)

    // 5. 顶部高光(上移的细描边,向下淡出)
    let spec = gradient([(rgb(0xFFFFFF, 0.85), 0), (rgb(0xFFFFFF, 0), 1)])
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 6)
    ctx.setAlpha(0.75)
    fill(ctx, ringOutline(width: ringWidth * 0.32), spec, top: 764, bottom: 404)
    // 运行点高光只保留在圆内,避免外圈出现灰边
    ctx.translateBy(x: 0, y: -6)
    ctx.addPath(dotPath())
    ctx.clip()
    ctx.translateBy(x: 0, y: 6)
    ctx.setAlpha(0.55)
    fill(ctx, dotPath().copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10), spec, top: 764, bottom: 404)
    ctx.restoreGState()
    ctx.restoreGState()

    // 6. 玻璃边缘:上亮、中段隐去、底部微亮
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let rim = shape.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 10)
    fill(ctx, rim, gradient([(rgb(0xFFFFFF, 0.38), 0), (rgb(0xFFFFFF, 0.06), 0.35), (rgb(0xFFFFFF, 0.02), 0.8), (rgb(0xFFFFFF, 0.14), 1)]),
         top: body.maxY, bottom: body.minY)
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// 写 PNG。
/// - Parameters:
///   - image: 图像
///   - url: 目标路径
func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(render(pixels: points * scale), to: iconset.appendingPathComponent(name))
}
writePNG(render(pixels: 1024), to: URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon-1024.png"))
print("已生成 \(iconset.path)")
