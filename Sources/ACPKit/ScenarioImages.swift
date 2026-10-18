// @author ixxxxoooo
// 演示场景用的图片:用 CoreGraphics 现场绘制示意性的页面截图(无文字,仅色块),
// 供「用户消息带图片」「浏览器截图」「读取图片」等场景使用;结果按种类缓存。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 场景图片的种类。
public enum ScenarioImageKind: Sendable, CaseIterable {
    /// 指标看板页面截图(顶栏、侧栏、统计卡、柱状图、表格)
    case dashboard
    /// 报错页面截图(红色告警条、堆栈块)
    case errorPage
    /// 渐变徽标
    case logo
}

/// 场景图片生成器。
public enum ScenarioImages {
    /// 缓存:同一种类只绘制一次。
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [ScenarioImageKind: Data] = [:]

        func value(_ kind: ScenarioImageKind, make: () -> Data) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let hit = store[kind] { return hit }
            let data = make()
            store[kind] = data
            return data
        }
    }

    /// 图片的 PNG 数据。
    /// - Parameter kind: 种类
    /// - Returns: PNG 数据;绘制失败时为空
    public static func png(_ kind: ScenarioImageKind) -> Data {
        cache.value(kind) { render(kind) }
    }

    /// 图片的 base64 文本(ACP `image` 内容块的 `data`)。
    /// - Parameter kind: 种类
    public static func base64(_ kind: ScenarioImageKind) -> String { png(kind).base64EncodedString() }

    /// 构造 ACP 图片内容块。
    /// - Parameter kind: 种类
    /// - Returns: `{type:image,data,mimeType}`
    public static func contentBlock(_ kind: ScenarioImageKind) -> JSONValue {
        ["type": "image", "data": .string(base64(kind)), "mimeType": "image/png"]
    }

    // MARK: 绘制

    private static func render(_ kind: ScenarioImageKind) -> Data {
        let size = kind == .logo ? CGSize(width: 256, height: 256) : CGSize(width: 960, height: 600)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        // 坐标系翻转为左上角原点,便于按版面书写
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        switch kind {
        case .dashboard: drawDashboard(context, size)
        case .errorPage: drawErrorPage(context, size)
        case .logo: drawLogo(context, size)
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    private static func fill(_ c: CGContext, _ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        c.setFillColor(color)
        if radius > 0 {
            c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.fillPath()
        } else {
            c.fill(rect)
        }
    }

    /// 浏览器窗口外壳:标题栏 + 三个圆点 + 地址栏。
    private static func drawChrome(_ c: CGContext, _ size: CGSize) {
        fill(c, CGRect(x: 0, y: 0, width: size.width, height: 44), color(232, 232, 236))
        for (index, tone) in [(255, 95, 87), (254, 188, 46), (40, 200, 64)].enumerated() {
            fill(c, CGRect(x: 18 + CGFloat(index) * 22, y: 15, width: 13, height: 13), color(tone.0, tone.1, tone.2), radius: 6.5)
        }
        fill(c, CGRect(x: 120, y: 10, width: size.width - 240, height: 24), color(250, 250, 252), radius: 8)
    }

    private static func drawDashboard(_ c: CGContext, _ size: CGSize) {
        fill(c, CGRect(origin: .zero, size: size), color(246, 246, 247))
        drawChrome(c, size)
        // 顶栏与侧栏
        fill(c, CGRect(x: 0, y: 44, width: size.width, height: 52), color(38, 38, 42))
        fill(c, CGRect(x: 24, y: 60, width: 120, height: 20), color(255, 255, 255, 0.85), radius: 6)
        fill(c, CGRect(x: 0, y: 96, width: 200, height: size.height - 96), color(236, 236, 239))
        for row in 0..<6 {
            let selected = row == 1
            fill(c, CGRect(x: 16, y: 116 + CGFloat(row) * 44, width: 168, height: 32), selected ? color(224, 122, 80, 0.22) : color(255, 255, 255, 0.0), radius: 8)
            fill(c, CGRect(x: 30, y: 126 + CGFloat(row) * 44, width: selected ? 110 : 90, height: 12), selected ? color(196, 92, 52) : color(160, 160, 168), radius: 4)
        }
        // 统计卡
        let tones = [color(224, 122, 80), color(64, 150, 110), color(86, 120, 200)]
        for index in 0..<3 {
            let x = 224 + CGFloat(index) * 244
            fill(c, CGRect(x: x, y: 116, width: 228, height: 96), color(255, 255, 255), radius: 12)
            fill(c, CGRect(x: x + 18, y: 132, width: 70, height: 10), color(170, 170, 178), radius: 4)
            fill(c, CGRect(x: x + 18, y: 156, width: 110, height: 28), tones[index], radius: 6)
        }
        // 柱状图
        fill(c, CGRect(x: 224, y: 232, width: 460, height: 232), color(255, 255, 255), radius: 12)
        let heights: [CGFloat] = [70, 110, 90, 150, 120, 176, 140, 190]
        for (index, h) in heights.enumerated() {
            fill(c, CGRect(x: 250 + CGFloat(index) * 52, y: 444 - h, width: 30, height: h), index == 7 ? color(224, 122, 80) : color(224, 122, 80, 0.4), radius: 5)
        }
        // 表格
        fill(c, CGRect(x: 704, y: 232, width: 232, height: 232), color(255, 255, 255), radius: 12)
        for row in 0..<7 {
            fill(c, CGRect(x: 722, y: 252 + CGFloat(row) * 28, width: 196, height: 10), row == 0 ? color(120, 120, 128) : color(205, 205, 210), radius: 4)
        }
        fill(c, CGRect(x: 224, y: 484, width: 712, height: 84), color(255, 255, 255), radius: 12)
        fill(c, CGRect(x: 244, y: 506, width: 380, height: 12), color(205, 205, 210), radius: 4)
        fill(c, CGRect(x: 244, y: 532, width: 260, height: 12), color(225, 225, 230), radius: 4)
    }

    private static func drawErrorPage(_ c: CGContext, _ size: CGSize) {
        fill(c, CGRect(origin: .zero, size: size), color(250, 250, 251))
        drawChrome(c, size)
        fill(c, CGRect(x: 48, y: 84, width: size.width - 96, height: 64), color(222, 70, 62, 0.14), radius: 12)
        fill(c, CGRect(x: 72, y: 108, width: 18, height: 18), color(210, 60, 52), radius: 9)
        fill(c, CGRect(x: 108, y: 108, width: 360, height: 14), color(190, 56, 48), radius: 5)
        fill(c, CGRect(x: 48, y: 172, width: size.width - 96, height: 376), color(30, 30, 34), radius: 12)
        for row in 0..<11 {
            let width = CGFloat(220 + (row * 53) % 380)
            fill(c, CGRect(x: 76, y: 198 + CGFloat(row) * 30, width: width, height: 10), row == 2 ? color(230, 110, 100) : color(130, 130, 140), radius: 4)
        }
    }

    private static func drawLogo(_ c: CGContext, _ size: CGSize) {
        c.saveGState()
        c.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 56, cornerHeight: 56, transform: nil))
        c.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(224, 122, 80), color(190, 84, 48)] as CFArray, locations: [0, 1]) {
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        c.restoreGState()
        c.setFillColor(color(255, 255, 255))
        c.move(to: CGPoint(x: 64, y: 184)); c.addLine(to: CGPoint(x: 128, y: 56)); c.addLine(to: CGPoint(x: 192, y: 184))
        c.addLine(to: CGPoint(x: 164, y: 184)); c.addLine(to: CGPoint(x: 128, y: 108)); c.addLine(to: CGPoint(x: 92, y: 184)); c.closePath()
        c.fillPath()
    }
}
