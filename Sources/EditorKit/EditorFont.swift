// @author ixxxxoooo
// 编辑器字体偏好:字体族、字号、行高。对齐 kuku 的「字体与排版」设置
// (代码字体默认系统等宽;编辑器字号默认 13、范围 11–20;行高 13px 时为 18px,随字号等比缩放)。

import AppKit

/// 编辑器字体偏好与解析。键与设置页 `@AppStorage` 同名,修改后立即生效。
@MainActor
public enum EditorFontPrefs {
    /// 字号偏好键(UserDefaults)。
    public static let sizeKey = "editor.fontSize"
    /// 字体族偏好键(UserDefaults)。
    public static let familyKey = "editor.fontFamily"

    /// 「系统等宽」标签:作为字体族偏好的默认值,表示使用系统等宽字体。
    public static let systemMonospace = "System monospace"

    /// 默认字号(pt),对齐 kuku 的 13。
    public static let defaultSize: CGFloat = 13
    /// 字号允许范围(pt),对齐 kuku 的 11–20。
    public static let sizeRange: ClosedRange<Double> = 11...20

    /// 参照字号与参照行高:13pt 对应 18pt 行高(kuku 的 `lineHeight: 18`),其他字号等比缩放。
    private static let referenceSize: CGFloat = 13
    private static let referenceLineHeight: CGFloat = 18

    /// 预置代码字体(对齐 kuku 的 `PRESET_CODE_FONTS`,第一项为系统默认)。
    public struct Preset: Sendable, Hashable, Identifiable {
        /// 字体族名(系统等宽为 `systemMonospace`)。
        public let value: String
        /// 简短说明。
        public let note: String
        public var id: String { value }
    }

    /// 预置字体列表。
    public static let presets: [Preset] = [
        Preset(value: systemMonospace, note: "系统默认等宽"),
        Preset(value: "JetBrains Mono", note: "开发者等宽"),
        Preset(value: "Fira Code", note: "支持连字"),
        Preset(value: "SF Mono", note: "Apple 原生等宽"),
        Preset(value: "Menlo", note: "macOS 经典等宽"),
        Preset(value: "Monaco", note: "macOS 紧凑等宽"),
        Preset(value: "Cascadia Code", note: "微软连字等宽"),
        Preset(value: "Source Code Pro", note: "Adobe 开源等宽"),
    ]

    /// 把偏好字号夹到允许范围内;未设置时返回默认值。
    /// - Parameter raw: 偏好里存的原始值
    /// - Returns: 合法字号
    public static func clampedSize(_ raw: Double?) -> CGFloat {
        guard let raw, raw.isFinite else { return defaultSize }
        return CGFloat(min(max(raw, sizeRange.lowerBound), sizeRange.upperBound))
    }

    /// 当前偏好字号。
    public static var preferredSize: CGFloat {
        clampedSize(UserDefaults.standard.object(forKey: sizeKey) as? Double)
    }

    /// 当前偏好字体族(空串视为系统等宽)。
    public static var preferredFamily: String {
        normalizedFamily(UserDefaults.standard.string(forKey: familyKey))
    }

    /// 规整字体族名:去首尾空白,空串或系统等宽的各种写法统一为 `systemMonospace`。
    /// - Parameter family: 原始字体族名
    /// - Returns: 规整后的字体族名
    public static func normalizedFamily(_ family: String?) -> String {
        let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = trimmed.lowercased()
        if trimmed.isEmpty || lowered == systemMonospace.lowercased() || lowered == "system-mono" { return systemMonospace }
        return trimmed
    }

    /// 本机已安装的字体族(小写,首次使用时读取一次)。
    private static let installedFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies.map { $0.lowercased() })

    /// 字体族是否已安装(系统等宽恒为真)。
    /// - Parameter family: 字体族名
    /// - Returns: 是否可用
    public static func isInstalled(_ family: String) -> Bool {
        let name = normalizedFamily(family)
        if name == systemMonospace { return true }
        return resolved(named: name, size: defaultSize) != nil
    }

    /// 按字体族与字号取字体;未安装时回退到系统等宽,保证不会因为字体缺失而显示异常。
    /// - Parameters:
    ///   - family: 字体族名(或具体字体名)
    ///   - size: 字号(pt),会被夹到允许范围
    /// - Returns: 编辑器使用的字体
    public static func font(family: String, size: CGFloat) -> NSFont {
        let pointSize = clampedSize(Double(size))
        let name = normalizedFamily(family)
        if name != systemMonospace, let font = resolved(named: name, size: pointSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// 当前偏好对应的字体。
    public static var preferredFont: NSFont { font(family: preferredFamily, size: preferredSize) }

    /// 行间距:使「字体自然行高 + 行间距」等于按字号缩放后的目标行高(13pt → 18pt)。
    /// 自然行高已大于目标时返回 0,不压缩行高。
    /// - Parameter font: 编辑器字体
    /// - Returns: 附加行间距(pt)
    public static func lineSpacing(for font: NSFont) -> CGFloat {
        let target = font.pointSize * referenceLineHeight / referenceSize
        let natural = font.ascender - font.descender + font.leading
        return max(0, (target - natural).rounded(toPlaces: 2))
    }

    /// 编辑器默认段落样式(只设置行间距,不改变对齐与缩进)。
    /// - Parameter font: 编辑器字体
    /// - Returns: 段落样式
    public static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing(for: font)
        return style
    }

    /// 解析字体族名或具体字体名;解析不到返回 nil。
    private static func resolved(named name: String, size: CGFloat) -> NSFont? {
        if installedFamilies.contains(name.lowercased()) {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
            if let font = NSFont(descriptor: descriptor, size: size) { return font }
        }
        // 兼容直接填写具体字体名(如 SFMono-Regular、JetBrainsMono-Regular)与 SF Mono 这类不在字体族列表里的系统字体
        if let font = NSFont(name: name, size: size) { return font }
        if name.lowercased() == "sf mono", let font = NSFont(name: "SFMono-Regular", size: size) { return font }
        return nil
    }
}

private extension CGFloat {
    /// 四舍五入到指定小数位。
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = CGFloat(pow(10.0, Double(places)))
        return (self * factor).rounded() / factor
    }
}
