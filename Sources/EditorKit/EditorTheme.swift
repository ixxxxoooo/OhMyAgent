// @author ygw
// 编辑器主题:纯色高对比背景,绝不使用玻璃或模糊。

import AppKit

/// 编辑器主题,颜色均为动态颜色,自动适配深浅色。
@MainActor
public struct EditorTheme {
    public var background: NSColor
    public var foreground: NSColor
    public var gutterBackground: NSColor
    public var gutterForeground: NSColor
    public var currentLine: NSColor
    public var font: NSFont
    public var colors: [SyntaxKind: NSColor]

    /// 用户设置的编辑器字号(键 `editor.fontSize`,默认 13,范围 11–20,对齐 kuku)。
    public static var preferredFontSize: CGFloat { EditorFontPrefs.preferredSize }

    /// 编辑器段落样式:按字体换算行高(13pt 时 18pt),行号栏与正文逐行对齐。
    public var paragraphStyle: NSParagraphStyle { EditorFontPrefs.paragraphStyle(for: font) }

    /// 默认主题。
    public static var `default`: EditorTheme {
        func dynamic(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        }
        return EditorTheme(
            background: dynamic(light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                dark: NSColor(srgbRed: 0.105, green: 0.109, blue: 0.121, alpha: 1)),
            foreground: dynamic(light: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                                dark: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1)),
            gutterBackground: dynamic(light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
                                      dark: NSColor(srgbRed: 0.125, green: 0.129, blue: 0.143, alpha: 1)),
            gutterForeground: dynamic(light: NSColor(srgbRed: 0.55, green: 0.56, blue: 0.60, alpha: 1),
                                      dark: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1)),
            currentLine: dynamic(light: NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1),
                                 dark: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 1)),
            font: EditorFontPrefs.preferredFont,
            colors: [
                .keyword: dynamic(light: NSColor(srgbRed: 0.68, green: 0.12, blue: 0.55, alpha: 1), dark: NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1)),
                .string: dynamic(light: NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1), dark: NSColor(srgbRed: 0.99, green: 0.42, blue: 0.36, alpha: 1)),
                .comment: dynamic(light: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.52, alpha: 1), dark: NSColor(srgbRed: 0.50, green: 0.55, blue: 0.60, alpha: 1)),
                .number: dynamic(light: NSColor(srgbRed: 0.11, green: 0.00, blue: 0.81, alpha: 1), dark: NSColor(srgbRed: 0.82, green: 0.75, blue: 0.40, alpha: 1)),
                .type: dynamic(light: NSColor(srgbRed: 0.11, green: 0.43, blue: 0.52, alpha: 1), dark: NSColor(srgbRed: 0.36, green: 0.80, blue: 0.85, alpha: 1)),
                .function: dynamic(light: NSColor(srgbRed: 0.23, green: 0.34, blue: 0.62, alpha: 1), dark: NSColor(srgbRed: 0.40, green: 0.65, blue: 0.99, alpha: 1)),
                .property: dynamic(light: NSColor(srgbRed: 0.30, green: 0.45, blue: 0.55, alpha: 1), dark: NSColor(srgbRed: 0.55, green: 0.75, blue: 0.80, alpha: 1)),
            ]
        )
    }
}
