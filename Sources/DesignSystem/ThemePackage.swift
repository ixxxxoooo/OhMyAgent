// @author ixxxxoooo
// 主题包:一套完整的界面/编辑器/Diff 配色(对标 kuku 的 7 套主题 + Claude Code 终端主题)。
// 纯数据,无视图依赖;运行时由 `ThemeRuntime` 持有当前选择,令牌(`OMColors` 等)从这里取色。

import AppKit
import SwiftUI

/// 无色彩空间歧义的 sRGB 颜色(0…1)。
public struct ThemeRGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// 用 0xRRGGBB 创建。
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// 用分量创建(自动夹到 0…1)。
    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// 从 `#RRGGBB` / `RRGGBB` 解析;非法返回 nil。
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// `#RRGGBB` 文本。
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    public var color: Color { Color(nsColor: nsColor) }

    /// 与另一颜色按比例混合(`amount` 为另一颜色的占比,0…1)。
    public func mixed(with other: ThemeRGB, _ amount: Double) -> ThemeRGB {
        let t = min(max(amount, 0), 1)
        return ThemeRGB(red: red + (other.red - red) * t, green: green + (other.green - green) * t, blue: blue + (other.blue - blue) * t)
    }

    /// 相对亮度(用于判断前景色)。
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

/// 主题调色板。
public struct ThemePalette: Sendable, Equatable {
    // 界面
    /// 内容区背景(会话流、编辑区、设置页右侧)。
    public var surface: ThemeRGB
    public var card: ThemeRGB
    /// 左/右侧栏与设置页左栏背景;nil 时由 `surface` 与前景色混合推导。
    public var sidebarBackground: ThemeRGB? = nil
    // 编辑器
    public var editorBackground: ThemeRGB
    public var editorForeground: ThemeRGB
    public var gutterBackground: ThemeRGB
    public var gutterForeground: ThemeRGB
    public var currentLine: ThemeRGB
    // 语义色
    public var accent: ThemeRGB
    /// 第二强调色:链接、次要徽标。
    public var accent2: ThemeRGB
    public var success: ThemeRGB
    public var danger: ThemeRGB
    public var warning: ThemeRGB
    // Diff 行背景(增/删)
    public var diffAdded: ThemeRGB
    public var diffRemoved: ThemeRGB
    // 语法
    public var keyword: ThemeRGB
    public var string: ThemeRGB
    public var comment: ThemeRGB
    public var number: ThemeRGB
    public var type: ThemeRGB
    public var function: ThemeRGB
    public var property: ThemeRGB

    /// 是否偏深色(按编辑器背景亮度)。
    public var isDark: Bool { editorBackground.luminance < 0.5 }
}

/// 主题明暗倾向。
public enum ThemeTone: String, Sendable {
    /// 跟随系统(使用系统语义色与「外观模式」设置)
    case system
    case light
    case dark
}

/// 主题分组(设置页分组展示)。
public enum ThemeGroup: String, CaseIterable, Sendable {
    case system, cursor, anthropic, claudeCode, opencode

    public var title: String {
        switch self {
        case .system: return String(localized: "系统")
        case .cursor: return "Cursor"
        case .anthropic: return "Anthropic"
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        }
    }
}

/// 主题包。
public struct ThemePackage: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let group: ThemeGroup
    public let tone: ThemeTone
    /// nil 表示系统主题(不覆盖任何颜色)
    public let palette: ThemePalette?

    /// 主题的默认强调色(系统主题为 nil)。
    public var defaultAccent: ThemeRGB? { palette?.accent }

    public static func == (lhs: ThemePackage, rhs: ThemePackage) -> Bool { lhs.id == rhs.id }
}

// MARK: - 预置主题

extension ThemePalette {
    /// 浅色基线(取自原有编辑器与 Diff 配色),各主题在其上覆盖。
    static let lightBase = ThemePalette(
        surface: ThemeRGB(hex: 0xFFFFFF), card: ThemeRGB(hex: 0xF9F9FB),
        editorBackground: ThemeRGB(hex: 0xFFFFFF), editorForeground: ThemeRGB(hex: 0x1A1A1F),
        gutterBackground: ThemeRGB(hex: 0xF7F7FA), gutterForeground: ThemeRGB(hex: 0x8C8F99), currentLine: ThemeRGB(hex: 0xEDF2FF),
        accent: ThemeRGB(hex: 0x0A6CFF), accent2: ThemeRGB(hex: 0x6B4FD6),
        success: ThemeRGB(hex: 0x1A7F37), danger: ThemeRGB(hex: 0xCF222E), warning: ThemeRGB(hex: 0xB25E09),
        diffAdded: ThemeRGB(hex: 0xE0F6E4), diffRemoved: ThemeRGB(hex: 0xFDE4E4),
        keyword: ThemeRGB(hex: 0xAD1F8C), string: ThemeRGB(hex: 0xC41A17), comment: ThemeRGB(hex: 0x6B7885),
        number: ThemeRGB(hex: 0x1C00CF), type: ThemeRGB(hex: 0x1C6E85), function: ThemeRGB(hex: 0x3B579E), property: ThemeRGB(hex: 0x4D738C)
    )

    /// 深色基线。
    static let darkBase = ThemePalette(
        surface: ThemeRGB(hex: 0x1B1C1F), card: ThemeRGB(hex: 0x252628),
        editorBackground: ThemeRGB(hex: 0x1B1C1F), editorForeground: ThemeRGB(hex: 0xDCDEE3),
        gutterBackground: ThemeRGB(hex: 0x202125), gutterForeground: ThemeRGB(hex: 0x73787F), currentLine: ThemeRGB(hex: 0x292E3B),
        accent: ThemeRGB(hex: 0x4C9AFF), accent2: ThemeRGB(hex: 0xB39DFF),
        success: ThemeRGB(hex: 0x4CC38A), danger: ThemeRGB(hex: 0xFF6B6B), warning: ThemeRGB(hex: 0xF0A04B),
        diffAdded: ThemeRGB(hex: 0x1C3825), diffRemoved: ThemeRGB(hex: 0x4A2125),
        keyword: ThemeRGB(hex: 0xFC5EA3), string: ThemeRGB(hex: 0xFC6B5C), comment: ThemeRGB(hex: 0x808C99),
        number: ThemeRGB(hex: 0xD1BF66), type: ThemeRGB(hex: 0x5CCCD9), function: ThemeRGB(hex: 0x66A6FC), property: ThemeRGB(hex: 0x8CBFCC)
    )

    /// 基于基线做局部覆盖。
    static func make(_ base: ThemePalette, _ edit: (inout ThemePalette) -> Void) -> ThemePalette {
        var copy = base
        edit(&copy)
        return copy
    }

    /// 统一设置编辑器与界面底色。
    mutating func setBackgrounds(surface: UInt32, card: UInt32, gutter: UInt32, currentLine: UInt32, sidebar: UInt32? = nil) {
        self.surface = ThemeRGB(hex: surface)
        sidebarBackground = sidebar.map { ThemeRGB(hex: $0) }
        self.card = ThemeRGB(hex: card)
        editorBackground = ThemeRGB(hex: surface)
        gutterBackground = ThemeRGB(hex: gutter)
        self.currentLine = ThemeRGB(hex: currentLine)
    }

    /// 统一设置语法色。
    mutating func setSyntax(keyword: UInt32, string: UInt32, comment: UInt32, number: UInt32, type: UInt32, function: UInt32, property: UInt32) {
        self.keyword = ThemeRGB(hex: keyword); self.string = ThemeRGB(hex: string); self.comment = ThemeRGB(hex: comment)
        self.number = ThemeRGB(hex: number); self.type = ThemeRGB(hex: type); self.function = ThemeRGB(hex: function)
        self.property = ThemeRGB(hex: property)
    }
}

extension ThemePackage {
    /// 跟随系统。
    public static let system = ThemePackage(id: "system", name: String(localized: "跟随系统"), group: .system, tone: .system, palette: nil)

    // Cursor 系
    static let cursorLight = ThemePackage(id: "cursor-light", name: String(localized: "Cursor 浅色"), group: .cursor, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xF6F6F7, card: 0xF3F3F3, gutter: 0xF3F3F3, currentLine: 0xEDEDED, sidebar: 0xEFEFEF)
        $0.editorForeground = ThemeRGB(hex: 0x141414)
        $0.accent = ThemeRGB(hex: 0x2778C1); $0.accent2 = ThemeRGB(hex: 0x6F4BB8)
        $0.setSyntax(keyword: 0x1F7A6A, string: 0xB8407C, comment: 0x8A8A8A, number: 0x8A6A1A, type: 0x1F5FA8, function: 0xB35A1F, property: 0x6A4FB8)
    })

    static let cursorLightColorblind = ThemePackage(id: "cursor-light-colorblind", name: String(localized: "Cursor 浅色(色盲友好)"), group: .cursor, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xF6F6F7, card: 0xF3F3F3, gutter: 0xF3F3F3, currentLine: 0xEDEDED, sidebar: 0xEFEFEF)
        $0.editorForeground = ThemeRGB(hex: 0x141414)
        $0.accent = ThemeRGB(hex: 0x0B5CAD); $0.accent2 = ThemeRGB(hex: 0x8A4DB5)
        // 蓝/橙代替红/绿
        $0.success = ThemeRGB(hex: 0x0969DA); $0.danger = ThemeRGB(hex: 0xC4640A)
        $0.diffAdded = ThemeRGB(hex: 0xDCEBFA); $0.diffRemoved = ThemeRGB(hex: 0xFCE9D2)
        $0.setSyntax(keyword: 0x1F7A6A, string: 0xB8407C, comment: 0x8A8A8A, number: 0x8A6A1A, type: 0x1F5FA8, function: 0xB35A1F, property: 0x6A4FB8)
    })

    static let cursorDark = ThemePackage(id: "cursor-dark", name: String(localized: "Cursor 深色"), group: .cursor, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x181818, card: 0x202020, gutter: 0x1C1C1C, currentLine: 0x262A33, sidebar: 0x141414)
        $0.editorForeground = ThemeRGB(hex: 0xE4E4E4); $0.gutterForeground = ThemeRGB(hex: 0x6D6D6D)
        $0.accent = ThemeRGB(hex: 0x81A1C1); $0.accent2 = ThemeRGB(hex: 0xB48EAD)
        $0.success = ThemeRGB(hex: 0xA3BE8C); $0.danger = ThemeRGB(hex: 0xBF616A); $0.warning = ThemeRGB(hex: 0xEBCB8B)
        $0.diffAdded = ThemeRGB(hex: 0x1B3A28); $0.diffRemoved = ThemeRGB(hex: 0x41222A)
        $0.setSyntax(keyword: 0x83D6C5, string: 0xE394DC, comment: 0x6D6D6D, number: 0xEBC88D, type: 0x87C3FF, function: 0xEFB080, property: 0xAAA0FA)
    })

    static let cursorDarkHC = ThemePackage(id: "cursor-dark-hc", name: String(localized: "Cursor 深色(高对比)"), group: .cursor, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x0A0A0A, card: 0x161616, gutter: 0x101010, currentLine: 0x1F2530, sidebar: 0x050505)
        $0.editorForeground = ThemeRGB(hex: 0xFFFFFF); $0.gutterForeground = ThemeRGB(hex: 0x9A9A9A)
        $0.accent = ThemeRGB(hex: 0x7CC4FF); $0.accent2 = ThemeRGB(hex: 0xFFD866)
        $0.success = ThemeRGB(hex: 0x5FE08A); $0.danger = ThemeRGB(hex: 0xFF7B7B)
        $0.diffAdded = ThemeRGB(hex: 0x0E3D1F); $0.diffRemoved = ThemeRGB(hex: 0x4D1118)
        $0.setSyntax(keyword: 0x8CE8D2, string: 0xFFA3F0, comment: 0x9A9A9A, number: 0xFFD98E, type: 0x9ED2FF, function: 0xFFC08F, property: 0xC0B8FF)
    })

    // Anthropic 系(品牌色 #D97757)
    static let anthropicLight = ThemePackage(id: "anthropic-light", name: String(localized: "Anthropic 浅色"), group: .anthropic, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFAF9F5, card: 0xF0EEE6, gutter: 0xF3F1EA, currentLine: 0xEFEBDD, sidebar: 0xF0EEE6)
        $0.editorForeground = ThemeRGB(hex: 0x141413); $0.gutterForeground = ThemeRGB(hex: 0x9A9484)
        $0.accent = ThemeRGB(hex: 0xD97757); $0.accent2 = ThemeRGB(hex: 0x5769F7)
        $0.success = ThemeRGB(hex: 0x5E7F3E); $0.danger = ThemeRGB(hex: 0xC4442F); $0.warning = ThemeRGB(hex: 0xB07A1E)
        $0.diffAdded = ThemeRGB(hex: 0xE6F0D9); $0.diffRemoved = ThemeRGB(hex: 0xFBE3DC)
        $0.setSyntax(keyword: 0xB5502F, string: 0x5E7F3E, comment: 0x8B8575, number: 0x5769F7, type: 0x8A5A9E, function: 0x2F6F9F, property: 0x6B5E4B)
    })

    static let anthropicDark = ThemePackage(id: "anthropic-dark", name: String(localized: "Anthropic 深色"), group: .anthropic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x141413, card: 0x1F1E1D, gutter: 0x181817, currentLine: 0x2A2825, sidebar: 0x0F0F0E)
        $0.editorForeground = ThemeRGB(hex: 0xE8E6DC); $0.gutterForeground = ThemeRGB(hex: 0x7D786C)
        $0.accent = ThemeRGB(hex: 0xE08A6B); $0.accent2 = ThemeRGB(hex: 0x8B9CFF)
        $0.success = ThemeRGB(hex: 0x9DB97A); $0.danger = ThemeRGB(hex: 0xE8705A); $0.warning = ThemeRGB(hex: 0xE0B35A)
        $0.diffAdded = ThemeRGB(hex: 0x24301C); $0.diffRemoved = ThemeRGB(hex: 0x40231D)
        $0.setSyntax(keyword: 0xE08A6B, string: 0xA9C27E, comment: 0x7D786C, number: 0x9AA8FF, type: 0xC9A0DC, function: 0x7FB2D9, property: 0xC2B8A3)
    })

    // Claude Code 系(语义色取自 Claude Code 终端主题)
    static let claudeDark = ThemePackage(id: "claude-dark", name: String(localized: "Claude Code 深色"), group: .claudeCode, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x171717, card: 0x212121, gutter: 0x1B1B1B, currentLine: 0x2A2724, sidebar: 0x121212)
        $0.editorForeground = ThemeRGB(hex: 0xEDEDED); $0.gutterForeground = ThemeRGB(hex: 0x777777)
        $0.accent = ThemeRGB(hex: 0xD77757); $0.accent2 = ThemeRGB(hex: 0xB1B9F9)
        $0.success = ThemeRGB(hex: 0x4EBA65); $0.danger = ThemeRGB(hex: 0xFF6B80); $0.warning = ThemeRGB(hex: 0xFFC107)
        $0.diffAdded = ThemeRGB(hex: 0x1D3A26); $0.diffRemoved = ThemeRGB(hex: 0x472029)
        $0.setSyntax(keyword: 0xF59575, string: 0x7FD08F, comment: 0x777777, number: 0xB1B9F9, type: 0xC9A7E6, function: 0x8CC4F0, property: 0xD8C7A8)
    })

    static let claudeLight = ThemePackage(id: "claude-light", name: String(localized: "Claude Code 浅色"), group: .claudeCode, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFFFFFF, card: 0xF6F4EF, gutter: 0xF5F3EE, currentLine: 0xF0ECE2, sidebar: 0xF6F4EF)
        $0.editorForeground = ThemeRGB(hex: 0x1A1A1A)
        $0.accent = ThemeRGB(hex: 0xD77757); $0.accent2 = ThemeRGB(hex: 0x5769F7)
        $0.success = ThemeRGB(hex: 0x2C7A39); $0.danger = ThemeRGB(hex: 0xAB2B3F); $0.warning = ThemeRGB(hex: 0x966C1E)
        $0.diffAdded = ThemeRGB(hex: 0xDDF0E0); $0.diffRemoved = ThemeRGB(hex: 0xF9DEE2)
        $0.setSyntax(keyword: 0xB5502F, string: 0x2C7A39, comment: 0x8B8575, number: 0x5769F7, type: 0x8A5A9E, function: 0x2F6F9F, property: 0x6B5E4B)
    })

    static let claudeDarkDaltonized = ThemePackage(id: "claude-dark-daltonized", name: String(localized: "Claude Code 深色(色盲友好)"), group: .claudeCode, tone: .dark, palette: .make(claudeDark.palette ?? .darkBase) {
        $0.success = ThemeRGB(hex: 0x3399FF); $0.danger = ThemeRGB(hex: 0xFF9966)
        $0.diffAdded = ThemeRGB(hex: 0x1A3552); $0.diffRemoved = ThemeRGB(hex: 0x4D3020)
    })

    static let claudeLightDaltonized = ThemePackage(id: "claude-light-daltonized", name: String(localized: "Claude Code 浅色(色盲友好)"), group: .claudeCode, tone: .light, palette: .make(claudeLight.palette ?? .lightBase) {
        $0.success = ThemeRGB(hex: 0x006699); $0.danger = ThemeRGB(hex: 0xCC5500)
        $0.diffAdded = ThemeRGB(hex: 0xD9EAF7); $0.diffRemoved = ThemeRGB(hex: 0xFBE4D0)
    })

    static let claudeDarkANSI = ThemePackage(id: "claude-dark-ansi", name: String(localized: "Claude Code 深色(ANSI)"), group: .claudeCode, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x0C0C0C, card: 0x1A1A1A, gutter: 0x121212, currentLine: 0x1F1F2E, sidebar: 0x080808)
        $0.editorForeground = ThemeRGB(hex: 0xE5E5E5)
        $0.accent = ThemeRGB(hex: 0xFF5555); $0.accent2 = ThemeRGB(hex: 0x5555FF)
        $0.success = ThemeRGB(hex: 0x55FF55); $0.danger = ThemeRGB(hex: 0xFF5555); $0.warning = ThemeRGB(hex: 0xFFFF55)
        $0.diffAdded = ThemeRGB(hex: 0x0F3A0F); $0.diffRemoved = ThemeRGB(hex: 0x4A1010)
        $0.setSyntax(keyword: 0xFF55FF, string: 0x55FF55, comment: 0x808080, number: 0xFFFF55, type: 0x55FFFF, function: 0x5555FF, property: 0xE5E5E5)
    })

    static let claudeLightANSI = ThemePackage(id: "claude-light-ansi", name: String(localized: "Claude Code 浅色(ANSI)"), group: .claudeCode, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFFFFFF, card: 0xF2F2F2, gutter: 0xF5F5F5, currentLine: 0xE8EEFF, sidebar: 0xF2F2F2)
        $0.editorForeground = ThemeRGB(hex: 0x000000)
        $0.accent = ThemeRGB(hex: 0xAA0000); $0.accent2 = ThemeRGB(hex: 0x0000AA)
        $0.success = ThemeRGB(hex: 0x00AA00); $0.danger = ThemeRGB(hex: 0xAA0000); $0.warning = ThemeRGB(hex: 0xAA5500)
        $0.diffAdded = ThemeRGB(hex: 0xD6F5D6); $0.diffRemoved = ThemeRGB(hex: 0xF8D6D6)
        $0.setSyntax(keyword: 0xAA00AA, string: 0x00AA00, comment: 0x777777, number: 0xAA5500, type: 0x00AAAA, function: 0x0000AA, property: 0x000000)
    })

    // OpenCode 系(取自 OpenCode 默认 TUI 主题:近黑底、桃橙主色、蓝/紫点缀)
    static let opencodeDark = ThemePackage(id: "opencode-dark", name: String(localized: "OpenCode 深色"), group: .opencode, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x0A0A0A, card: 0x141414, gutter: 0x0F0F0F, currentLine: 0x1E1E1E, sidebar: 0x050505)
        $0.editorForeground = ThemeRGB(hex: 0xEEEEEE); $0.gutterForeground = ThemeRGB(hex: 0x606060)
        $0.accent = ThemeRGB(hex: 0xFAB283); $0.accent2 = ThemeRGB(hex: 0x5C9CF5)
        $0.success = ThemeRGB(hex: 0x7FD88F); $0.danger = ThemeRGB(hex: 0xE06C75); $0.warning = ThemeRGB(hex: 0xF5A742)
        $0.diffAdded = ThemeRGB(hex: 0x1B3322); $0.diffRemoved = ThemeRGB(hex: 0x3F1F24)
        $0.setSyntax(keyword: 0x9D7CD8, string: 0x7FD88F, comment: 0x808080, number: 0xF5A742, type: 0xE5C07B, function: 0xFAB283, property: 0xE06C75)
    })

    static let opencodeLight = ThemePackage(id: "opencode-light", name: String(localized: "OpenCode 浅色"), group: .opencode, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFFFFFF, card: 0xF5F5F5, gutter: 0xFAFAFA, currentLine: 0xF0F0F0, sidebar: 0xF3F3F3)
        $0.editorForeground = ThemeRGB(hex: 0x1A1A1A); $0.gutterForeground = ThemeRGB(hex: 0x9A9A9A)
        $0.accent = ThemeRGB(hex: 0x3B7DD8); $0.accent2 = ThemeRGB(hex: 0x7B5BB6)
        $0.success = ThemeRGB(hex: 0x3D9A57); $0.danger = ThemeRGB(hex: 0xD1383D); $0.warning = ThemeRGB(hex: 0xD68C27)
        $0.diffAdded = ThemeRGB(hex: 0xDDF2E3); $0.diffRemoved = ThemeRGB(hex: 0xFBE0E1)
        $0.setSyntax(keyword: 0x7B5BB6, string: 0x3D9A57, comment: 0x8A8A8A, number: 0xD68C27, type: 0xB0851F, function: 0x3B7DD8, property: 0xD1383D)
    })

    /// 全部预置主题(设置页按分组展示)。
    public static let all: [ThemePackage] = [
        system,
        cursorLight, cursorLightColorblind, cursorDark, cursorDarkHC,
        anthropicLight, anthropicDark,
        claudeDark, claudeLight, claudeDarkDaltonized, claudeLightDaltonized, claudeDarkANSI, claudeLightANSI,
        opencodeDark, opencodeLight,
    ]

    /// 按 id 查找,未知回退系统。
    public static func find(_ id: String) -> ThemePackage { all.first { $0.id == id } ?? .system }
}

// MARK: - 运行时

/// 当前主题与强调色覆盖(由 `AppearanceModel` 写入;只在主线程的界面刷新周期读取)。
public enum ThemeRuntime {
    nonisolated(unsafe) public static var package: ThemePackage = .system
    /// 用户选择的主强调色(nil = 跟随主题默认)
    nonisolated(unsafe) public static var accentOverride: ThemeRGB?
    /// 用户选择的第二强调色(nil = 跟随主题默认)
    nonisolated(unsafe) public static var accent2Override: ThemeRGB?

    /// 当前调色板(系统主题为 nil)。
    public static var palette: ThemePalette? { package.palette }

    /// 生效的主强调色;nil 表示使用系统强调色。
    public static var accent: ThemeRGB? { accentOverride ?? palette?.accent }
    /// 生效的第二强调色;nil 表示回退为系统强调色。
    public static var accent2: ThemeRGB? { accent2Override ?? palette?.accent2 }

    /// 主题变化通知(编辑器据此重新应用配色、清空高亮缓存)。
    public static let didChange = Notification.Name("OMThemeDidChange")
}
