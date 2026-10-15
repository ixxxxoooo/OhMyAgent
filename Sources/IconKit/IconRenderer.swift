// @author ygw
// Lucide 图标渲染:SVG path → CGPath → 模板化 NSImage(分辨率无关,自动适配深浅色与着色)。
// 同一份 NSImage 可用于 SwiftUI `Image`、菜单项、工具栏与 `NSStatusItem`。

import AppKit
import Foundation
import OMLog
import SwiftUI

/// 图标线宽。
public enum OMIconWeight: Sendable {
    case light, regular, bold

    /// 24 视口下的 Lucide 描边宽度。
    var stroke: CGFloat {
        switch self {
        case .light: 1.5
        case .regular: 2
        case .bold: 2.5
        }
    }
}

/// 图标渲染器。
public enum OMIconRenderer {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: Path] = [:]
        private let images = NSCache<NSString, NSImage>()

        func path(_ name: String) -> Path? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = paths[name] { return cached }
            guard let data = LucideData.icons[name] else { return nil }
            do {
                let parsed = try SVGPathParser.parse(all: data)
                paths[name] = parsed
                return parsed
            } catch {
                Log.ui.error("图标路径解析失败", error: error, ["icon": name])
                return nil
            }
        }

        func image(_ key: String) -> NSImage? { images.object(forKey: key as NSString) }
        func store(_ image: NSImage, _ key: String) { images.setObject(image, forKey: key as NSString) }
    }

    private static let cache = Cache()

    /// 取得图标路径(24×24 坐标)。
    /// - Parameter lucideName: Lucide 图标名
    /// - Returns: 路径;未知名称或解析失败返回 nil
    public static func path(lucideName: String) -> Path? { cache.path(lucideName) }

    /// 生成模板 NSImage。
    /// - Parameters:
    ///   - symbol: 语义名或 Lucide 名
    ///   - size: 边长(点)
    ///   - weight: 线宽
    /// - Returns: 模板图像;未知图标回退为同名 SF Symbol,再不行返回空图像
    public static func nsImage(_ symbol: String, size: CGFloat = 14, weight: OMIconWeight = .regular) -> NSImage {
        guard let lucide = IconCatalog.lucideName(for: symbol), let path = cache.path(lucide) else {
            Log.ui.warning("未知图标,回退 SF Symbol", ["symbol": symbol])
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: size, height: size))
        }
        let filled = IconCatalog.filledSymbols.contains(symbol)
        let key = "\(lucide)|\(size)|\(weight.stroke)|\(filled)"
        if let cached = cache.image(key) { return cached }
        let cgPath = path.cgPath
        // 小尺寸时保证实际线宽不低于约 1pt,避免发虚
        let stroke = max(weight.stroke, 1.1 * 24 / max(size, 1))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.setLineWidth(stroke)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(cgPath)
            context.drawPath(using: filled ? .fillStroke : .stroke)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        cache.store(image, key)
        return image
    }
}

public extension Image {
    /// Lucide 图标(模板渲染,随 `foregroundStyle` 着色)。
    /// - Parameters:
    ///   - symbol: 语义名或 Lucide 名
    ///   - size: 边长(点),默认 14
    ///   - weight: 线宽
    static func om(_ symbol: String, size: CGFloat = 14, weight: OMIconWeight = .regular) -> Image {
        Image(nsImage: OMIconRenderer.nsImage(symbol, size: size, weight: weight)).renderingMode(.template)
    }
}

public extension Label where Title == Text, Icon == Image {
    /// 使用 Lucide 图标的 Label(本地化字面量标题)。
    init(_ titleKey: LocalizedStringKey, om symbol: String, size: CGFloat = 14) {
        self.init { Text(titleKey) } icon: { Image.om(symbol, size: size) }
    }

    /// 使用 Lucide 图标的 Label(动态字符串标题)。
    init<S: StringProtocol>(_ title: S, om symbol: String, size: CGFloat = 14) {
        self.init { Text(title) } icon: { Image.om(symbol, size: size) }
    }
}
