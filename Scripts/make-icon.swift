#!/usr/bin/env swift
// @author ygw
// 程序化绘制 OhMyAgent 应用图标(macOS 图标规范:1024 画布,824 圆角方形主体 + 柔和投影),
// 输出 AppIcon.iconset 全部尺寸并交给 iconutil 生成 icns。
// 用法: swift Scripts/make-icon.swift <输出目录>   (默认 build/icon)

import AppKit
import CoreGraphics
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"

/// 超椭圆(squircle)路径:|x/a|^n + |y/a|^n = 1,n≈4.4 更接近 macOS 图标的连续曲率圆角。
func squirclePath(rect: CGRect, exponent n: CGFloat = 4.4) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 四角星(星芒):四个尖角,边向中心内凹。
func sparkPath(center: CGPoint, radius r: CGFloat, waist: CGFloat = 0.16) -> CGPath {
    let p = CGMutablePath()
    let top = CGPoint(x: center.x, y: center.y + r)
    let right = CGPoint(x: center.x + r, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - r)
    let left = CGPoint(x: center.x - r, y: center.y)
    let k = r * waist
    p.move(to: top)
    p.addQuadCurve(to: right, control: CGPoint(x: center.x + k, y: center.y + k))
    p.addQuadCurve(to: bottom, control: CGPoint(x: center.x + k, y: center.y - k))
    p.addQuadCurve(to: left, control: CGPoint(x: center.x - k, y: center.y - k))
    p.addQuadCurve(to: top, control: CGPoint(x: center.x - k, y: center.y + k))
    p.closeSubpath()
    return p
}

/// 渲染指定像素尺寸的图标。
func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(rect: body)

    // 1. 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.38))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 主体渐变(左上紫 → 中蓝 → 右下青)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [
        CGColor(red: 0.36, green: 0.22, blue: 0.96, alpha: 1),
        CGColor(red: 0.15, green: 0.39, blue: 0.93, alpha: 1),
        CGColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // 3. 顶部柔光(玻璃高光)
    let gloss = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: body.midX - 120, y: body.maxY + 40), startRadius: 0,
                           endCenter: CGPoint(x: body.midX - 120, y: body.maxY + 40), endRadius: 620, options: [])
    // 底部暗角,增加体积感
    let vignette = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.22)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(vignette, start: CGPoint(x: body.midX, y: body.midY), end: CGPoint(x: body.midX, y: body.minY), options: [])

    // 4. 星芒:主星 + 副星,带柔和发光
    let main = sparkPath(center: CGPoint(x: 500, y: 500), radius: 270, waist: 0.14)
    let small = sparkPath(center: CGPoint(x: 700, y: 690), radius: 92, waist: 0.14)
    for (path, glow) in [(main, CGFloat(60)), (small, CGFloat(30))] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glow, color: CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.75))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let fill = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(red: 0.80, green: 0.89, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
        let box = path.boundingBox
        ctx.drawLinearGradient(fill, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
        ctx.restoreGState()
    }
    // 小圆点点缀(像 Agent 的"运行指示")
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: 292, y: 262, width: 34, height: 34))
    ctx.restoreGState()

    // 5. 内描边(上亮下暗),模拟玻璃边缘
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setLineWidth(5)
    let rim = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0.05)] as CFArray, locations: [0, 1])!
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(rim, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// 写 PNG。
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
