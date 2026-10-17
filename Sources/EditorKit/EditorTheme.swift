// @author ixxxxoooo
// 编辑器主题:纯色高对比背景,绝不使用玻璃或模糊。

import AppKit
import DesignSystem

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
        var theme = ThemeRuntime.palette.map { themed($0) } ?? systemDefault
        theme.applySyntaxPreferences(darkTheme: ThemeRuntime.palette?.isDark)
        return theme
    }

    /// 叠加用户在设置里选的代码高亮方案与单项自定义(没有任何指定时保持主题自带的语法色)。
    /// - Parameter darkTheme: 主题包自带明暗;系统主题为 nil,此时生成随外观切换的动态色
    mutating func applySyntaxPreferences(darkTheme: Bool?) {
        guard SyntaxPrefs.isActive else { return }
        for token in SyntaxToken.allCases {
            guard let kind = Self.kind(for: token) else { continue }
            if let isDark = darkTheme {
                if let rgb = SyntaxPrefs.color(token, dark: isDark) { colors[kind] = rgb.nsColor }
            } else {
                let base = colors[kind]
                let light = SyntaxPrefs.color(token, dark: false), dark = SyntaxPrefs.color(token, dark: true)
                guard light != nil || dark != nil else { continue }
                colors[kind] = NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return (isDark ? dark : light)?.nsColor ?? base ?? .textColor
                }
            }
        }
    }

    /// 某个语法项当前生效的颜色(含方案与自定义),设置页的取色器与预览用。
    /// - Parameter token: 语法项
    /// - Returns: 颜色
    public static func syntaxColor(_ token: SyntaxToken) -> NSColor {
        let theme = EditorTheme.default
        return kind(for: token).flatMap { theme.colors[$0] } ?? theme.foreground
    }

    private static func kind(for token: SyntaxToken) -> SyntaxKind? {
        switch token {
        case .keyword: return .keyword
        case .string: return .string
        case .comment: return .comment
        case .number: return .number
        case .type: return .type
        case .function: return .function
        case .property: return .property
        }
    }

    /// 由主题包调色板生成的编辑器主题。
    static func themed(_ palette: ThemePalette) -> EditorTheme {
        EditorTheme(
            background: palette.editorBackground.nsColor,
            foreground: palette.editorForeground.nsColor,
            gutterBackground: palette.gutterBackground.nsColor,
            gutterForeground: palette.gutterForeground.nsColor,
            currentLine: palette.currentLine.nsColor,
            font: EditorFontPrefs.preferredFont,
            colors: [
                .keyword: palette.keyword.nsColor, .string: palette.string.nsColor, .comment: palette.comment.nsColor,
                .number: palette.number.nsColor, .type: palette.type.nsColor, .function: palette.function.nsColor,
                .property: palette.property.nsColor,
            ]
        )
    }

    /// 系统主题(随系统深浅色自动切换)。
    private static var systemDefault: EditorTheme {
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
