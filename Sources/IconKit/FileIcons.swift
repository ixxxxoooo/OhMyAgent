// @author ixxxxoooo
// 彩色文件类型图标:数据来自 Material Icon Theme(见 `FileIconData`),按文件名/扩展名/文件夹名解析,
// 渲染为非模板 NSImage(自带配色,深浅色下均清晰)。界面中的功能图标仍用 Lucide(单色模板)。

import AppKit
import Foundation
import OMLog
import SwiftUI

/// 文件图标解析:把文件/文件夹名映射到图标名。
public enum OMFileIconCatalog {
    private static let lowerFolders: [String: String] = Dictionary(
        FileIconData.folders.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    private static let lowerFolderOpen: [String: String] = Dictionary(
        FileIconData.foldersOpen.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    private static let lowerFileNames: [String: String] = Dictionary(
        FileIconData.fileNames.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

    /// 解析图标名。
    /// - Parameters:
    ///   - name: 文件或文件夹的名称(不含路径)
    ///   - isDirectory: 是否文件夹
    ///   - expanded: 文件夹是否展开
    /// - Returns: 图标名(一定存在于 `FileIconData.icons`)
    public static func iconName(for name: String, isDirectory: Bool, expanded: Bool = false) -> String {
        if isDirectory {
            let table = expanded ? lowerFolderOpen : lowerFolders
            return table[name.lowercased()] ?? (expanded ? FileIconData.defaultFolderOpen : FileIconData.defaultFolder)
        }
        if let hit = FileIconData.fileNames[name] ?? lowerFileNames[name.lowercased()] { return hit }
        // 扩展名:取最后一段;点开头的隐藏文件(.gitignore)整体去掉前导点后当扩展名
        let lower = name.lowercased()
        let ext = lower.hasPrefix(".") && lower.dropFirst().firstIndex(of: ".") == nil
            ? String(lower.dropFirst())
            : (lower.split(separator: ".").dropFirst().last.map(String.init) ?? "")
        if !ext.isEmpty, let hit = FileIconData.extensions[ext] { return hit }
        return FileIconData.defaultFile
    }
}

public extension OMFileIconCatalog {
    /// 彩色文件类型图标的 `NSImage`(AppKit 列表/表格用,带缓存)。
    /// - Parameters:
    ///   - name: 文件或文件夹名称
    ///   - isDirectory: 是否文件夹
    ///   - expanded: 文件夹是否展开
    ///   - size: 边长(点)
    /// - Returns: 图像;数据缺失返回 nil
    @MainActor
    static func nsImage(name: String, isDirectory: Bool = false, expanded: Bool = false, size: CGFloat = 16) -> NSImage? {
        OMFileIconRenderer.image(icon: iconName(for: name, isDirectory: isDirectory, expanded: expanded), size: size)
    }
}

/// 文件图标渲染器。
enum OMFileIconRenderer {
    /// `NSCache` 本身线程安全,这里仅为满足 Sendable 检查而包装。
    private final class ImageCache: @unchecked Sendable {
        private let storage = NSCache<NSString, NSImage>()
        func get(_ key: NSString) -> NSImage? { storage.object(forKey: key) }
        func set(_ image: NSImage, _ key: NSString) { storage.setObject(image, forKey: key) }
    }

    private static let cache = ImageCache()

    /// 生成彩色图标图像。
    /// - Parameters:
    ///   - icon: 图标名
    ///   - size: 边长(点)
    /// - Returns: 图像;数据缺失或解析失败返回 nil
    static func image(icon: String, size: CGFloat) -> NSImage? {
        let key = "\(icon)|\(size)" as NSString
        if let cached = cache.get(key) { return cached }
        guard let spec = FileIconData.icons[icon] else { return nil }
        let lines = spec.split(separator: "\n", omittingEmptySubsequences: true)
        // 首行:视口边长,可选 viewBox 原点「minX minY」(Material Symbols 为 0 -960)
        let head = lines.first?.split(separator: " ").compactMap { Double($0) } ?? []
        guard let viewBox = head.first, viewBox > 0 else { return nil }
        let originX = head.count >= 3 ? head[1] : 0
        let originY = head.count >= 3 ? head[2] : 0
        var layers: [(NSColor, CGFloat, CGPath)] = []
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let color = NSColor(hex: String(parts[0])) else { continue }
            do {
                let path = try SVGPathParser.parse(String(parts[2])).cgPath
                layers.append((color, CGFloat(Double(parts[1]) ?? 1), path))
            } catch {
                Log.ui.error("文件图标路径解析失败", error: error, ["icon": icon])
            }
        }
        guard !layers.isEmpty else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / viewBox, y: rect.height / viewBox)
            context.translateBy(x: -originX, y: -originY)
            for (color, opacity, path) in layers {
                context.setFillColor(color.withAlphaComponent(opacity).cgColor)
                context.addPath(path)
                context.fillPath()
            }
            return true
        }
        cache.set(image, key)
        return image
    }
}

private extension NSColor {
    /// 解析 `#rgb` / `#rrggbb`。
    convenience init?(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// 彩色文件类型图标视图。
public struct OMFileIcon: View {
    private let icon: String
    private let size: CGFloat

    /// - Parameters:
    ///   - name: 文件或文件夹名称
    ///   - isDirectory: 是否文件夹
    ///   - expanded: 文件夹是否展开
    ///   - size: 边长(点)
    public init(name: String, isDirectory: Bool = false, expanded: Bool = false, size: CGFloat = 16) {
        icon = OMFileIconCatalog.iconName(for: name, isDirectory: isDirectory, expanded: expanded)
        self.size = size
    }

    public var body: some View {
        if let image = OMFileIconRenderer.image(icon: icon, size: size) {
            Image(nsImage: image).renderingMode(.original).accessibilityHidden(true)
        } else {
            Image.om(isFolderIcon ? "folder" : "file", size: size).foregroundStyle(.secondary)
        }
    }

    private var isFolderIcon: Bool { icon.hasPrefix("folder") }
}
