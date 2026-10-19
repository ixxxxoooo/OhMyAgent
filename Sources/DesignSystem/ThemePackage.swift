// @author ixxxxoooo
// 主题包:一套完整的界面/编辑器/Diff 配色(对标 kuku 的 7 套主题 + Claude Code 终端主题)。
// 纯数据,无视图依赖;运行时由 `ThemeRuntime` 持有当前选择,令牌(`OMColors` 等)从这里取色。

import AppKit
import Observation
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

    /// WCAG 相对亮度(sRGB 线性化)。
    private var wcagLuminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// 与另一颜色的 WCAG 对比度(1…21)。
    /// - Parameter other: 另一颜色
    public func contrast(with other: ThemeRGB) -> Double {
        let a = wcagLuminance, b = other.wcagLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// 在填充色 `self` 之上,从 `light`/`dark` 两个候选里选对比度更高的前景。
    public func readableForeground(light: ThemeRGB, dark: ThemeRGB) -> ThemeRGB {
        contrast(with: light) >= contrast(with: dark) ? light : dark
    }
}

/// 主题调色板。
public struct ThemePalette: Sendable, Equatable {
    // 界面
    /// 内容区背景(会话流、编辑区、设置页右侧)。
    public var surface: ThemeRGB
    public var card: ThemeRGB
    /// 左侧栏与设置页左栏背景;nil 时由 `surface` 与前景色混合推导。
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
    /// 主题风格(圆角/描边/阴影/玻璃着色);默认标准风格。
    public var style: ThemeStyle = .standard
    // 纸感规范新增的可选令牌(nil 时回退到旧行为,其他主题零变化)
    /// 强调色实底上的前景;nil 为白色。
    public var onAccent: ThemeRGB? = nil
    /// 小字号链接/强调用的加深强调色(保证 ≥ 4.5:1);nil 时取 `accent`。
    public var accentText: ThemeRGB? = nil
    /// 「继续/执行计划」类暖色动作按钮填充;nil 时取 `warning`。
    public var actionWarm: ThemeRGB? = nil
    /// 「提交/创建 PR」类正向动作按钮填充;nil 时取 `success`。
    public var actionPositive: ThemeRGB? = nil
    /// 输入框、次按钮等描边色;nil 时取 `hairline`。
    public var outline: ThemeRGB? = nil
    /// 在任意填充色上选取可读前景(候选为纸感的 Parchment / Ink)。
    public func readableForeground(on fill: ThemeRGB) -> ThemeRGB {
        fill.readableForeground(light: ThemeRGB(hex: 0xF7F7F4), dark: ThemeRGB(hex: 0x26251E))
    }
    /// 文字选区底色;nil 时取强调色。
    public var selection: ThemeRGB? = nil
    /// 次要文字显式取色;nil 时由前景向底色混合推导。
    public var secondaryTextColor: ThemeRGB? = nil
    /// 三级文字显式取色;nil 时由前景向底色混合推导。
    public var tertiaryTextColor: ThemeRGB? = nil
    /// 终端 ANSI 16 色(0–7 标准色,8–15 高亮色);nil 时由语义色与语法色推导。
    public var ansi: [ThemeRGB]? = nil

    /// 是否偏深色(按编辑器背景亮度)。
    public var isDark: Bool { editorBackground.luminance < 0.5 }
}

/// 主题风格:让每个主题不仅换色,还有各自的圆角、描边、阴影与玻璃着色。
public struct ThemeStyle: Sendable, Equatable {
    /// 圆角倍率(1 = 标准;<1 更方正,>1 更圆润)
    public var cornerScale: Double
    /// 描边(分隔线)强度倍率
    public var strokeScale: Double
    /// 阴影强度倍率
    public var shadowScale: Double
    /// 玻璃卡片的强调色着色强度(0 = 无着色)
    public var glassTint: Double
    /// 悬停/选中填充强度倍率
    public var fillScale: Double
    /// 是否允许 Liquid Glass;false 时所有玻璃走不透明回退(卡片色 + 描边),纸感主题为 false。
    public var allowsGlass: Bool
    /// 语义圆角集合;nil 沿用旧行为(按 `cornerScale` 缩放的默认取值)。
    public var radiusSet: ThemeRadiusSet?
    /// 主按钮与控件「开」态的填充来源。
    public var primaryButton: PrimaryButtonFill
    /// 选中态填充的色调来源。
    public var selectionTint: SelectionTint
    /// 卡片是否完全平面(只描边、无阴影);纸感为 true。
    public var flatCards: Bool

    /// 主按钮填充来源。
    public enum PrimaryButtonFill: Sendable, Equatable {
        /// 强调色实底(旧行为)
        case accent
        /// 墨色实底(纸感:强调色只用于文字)
        case ink
    }

    /// 选中态色调来源。
    public enum SelectionTint: Sendable, Equatable {
        /// 强调色洗色(旧行为)
        case accent
        /// 中性墨色填充(纸感:不使用强调色洗色)
        case neutral
    }

    public init(cornerScale: Double = 1, strokeScale: Double = 1, shadowScale: Double = 1, glassTint: Double = 0, fillScale: Double = 1,
                allowsGlass: Bool = true, radiusSet: ThemeRadiusSet? = nil, primaryButton: PrimaryButtonFill = .accent, selectionTint: SelectionTint = .accent, flatCards: Bool = false) {
        self.cornerScale = cornerScale
        self.strokeScale = strokeScale
        self.shadowScale = shadowScale
        self.glassTint = glassTint
        self.fillScale = fillScale
        self.allowsGlass = allowsGlass
        self.radiusSet = radiusSet
        self.primaryButton = primaryButton
        self.selectionTint = selectionTint
        self.flatCards = flatCards
    }

    /// 标准风格。
    public static let standard = ThemeStyle()
}

/// 语义圆角集合(单位 pt)。纸感主题:控件/卡片/标签 4,浮层/弹窗 8。
public struct ThemeRadiusSet: Sendable, Equatable {
    /// 标签、徽标、紧凑按钮、行内 chip
    public var tag: Double
    /// 按钮、输入框、列表行
    public var control: Double
    /// 卡片、代码块、工具卡
    public var card: Double
    /// 下拉、弹出菜单等轻浮层
    public var floating: Double
    /// 模态窗、搜索窗、输入框坞等大浮层
    public var modal: Double

    public init(tag: Double, control: Double, card: Double, floating: Double, modal: Double) {
        self.tag = tag
        self.control = control
        self.card = card
        self.floating = floating
        self.modal = modal
    }

    /// 纸感:全站 4,浮层/弹窗 8。
    public static let paper = ThemeRadiusSet(tag: 4, control: 4, card: 4, floating: 8, modal: 8)
}

// MARK: - 派生令牌

extension ThemePalette {
    /// 正文前景色。
    public var foreground: ThemeRGB { editorForeground }
    /// 次要文字:前景向底色混合。
    public var secondaryText: ThemeRGB { secondaryTextColor ?? editorForeground.mixed(with: surface, 0.40) }
    /// 三级文字(占位、禁用)。
    public var tertiaryText: ThemeRGB { tertiaryTextColor ?? editorForeground.mixed(with: surface, 0.62) }
    /// 分隔线:底色向前景轻微混合。
    public var hairline: ThemeRGB { surface.mixed(with: editorForeground, 0.14 * style.strokeScale) }

    /// 终端 ANSI 16 色:显式提供优先,否则由语义色/语法色推导,保证每个主题的终端都有自己的味道。
    public var ansiColors: [ThemeRGB] {
        if let ansi, ansi.count == 16 { return ansi }
        let black = isDark ? surface.mixed(with: editorForeground, 0.22) : editorForeground.mixed(with: surface, 0.10)
        let white = isDark ? editorForeground.mixed(with: surface, 0.18) : surface.mixed(with: editorForeground, 0.22)
        // 蓝/品红/青从候选里挑与已选颜色不同的,避免语法色与语义色撞车导致终端里两种颜色一样
        var used: Set<String> = [black, danger, success, warning, white].map(\.hexString).reduce(into: Set<String>()) { $0.insert($1) }
        func pick(_ candidates: [ThemeRGB]) -> ThemeRGB {
            let chosen = candidates.first { !used.contains($0.hexString) } ?? candidates[0].mixed(with: editorForeground, 0.25)
            used.insert(chosen.hexString)
            return chosen
        }
        let blue = pick([function, accent, property, type])
        let magenta = pick([keyword, accent2, number, string])
        let cyan = pick([type, property, accent, function, number])
        let base: [ThemeRGB] = [black, danger, success, warning, blue, magenta, cyan, white]
        let lift = isDark ? editorForeground : surface
        var bright = base.map { $0.mixed(with: lift, isDark ? 0.22 : 0.0) }
        if !isDark { bright = base.map { $0.mixed(with: editorForeground, 0.18) } }
        bright[0] = isDark ? comment : editorForeground.mixed(with: surface, 0.40)
        bright[7] = isDark ? editorForeground : surface
        return base + bright
    }
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
    case system
    /// Cursor 纸感(默认主题,规范见 AGENTS.md 4.4)
    case paper
    case cursor, anthropic, claudeCode, opencode
    /// 经典配色(Nord、Dracula、Solarized 等社区流行方案)
    case classic
    /// 用户自定义/导入的主题
    case custom

    public var title: String {
        switch self {
        case .system: return String(localized: "系统")
        case .paper: return String(localized: "纸感")
        case .cursor: return "Cursor"
        case .anthropic: return "Anthropic"
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        case .classic: return String(localized: "经典配色")
        case .custom: return String(localized: "自定义")
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

    public init(id: String, name: String, group: ThemeGroup, tone: ThemeTone, palette: ThemePalette?) {
        self.id = id
        self.name = name
        self.group = group
        self.tone = tone
        self.palette = palette
    }

    /// 主题的默认强调色(系统主题为 nil)。
    public var defaultAccent: ThemeRGB? { palette?.accent }

    public static func == (lhs: ThemePackage, rhs: ThemePackage) -> Bool { lhs.id == rhs.id }
}

// MARK: - 预置主题

extension ThemePalette {
    /// 浅色基线(取自原有编辑器与 Diff 配色),各主题在其上覆盖。
    public static let lightBase = ThemePalette(
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
    public static let darkBase = ThemePalette(
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
    public static func make(_ base: ThemePalette, _ edit: (inout ThemePalette) -> Void) -> ThemePalette {
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

    // 纸感系(默认):暖纸画布、墨色文字、强调色只用于文字;规范见 AGENTS.md 4.4
    /// 纸感浅色:Parchment 画布 / Bone 卡片 / Ink 墨色 / Ember 文字强调。
    static let paperLight = ThemePackage(id: "paper-light", name: String(localized: "Cursor 纸感"), group: .paper, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xF7F7F4, card: 0xF2F1ED, gutter: 0xF2F1ED, currentLine: 0xECEBE6, sidebar: 0xEFEEE9)
        $0.editorForeground = ThemeRGB(hex: 0x26251E); $0.gutterForeground = ThemeRGB(hex: 0x7A7974)
        $0.accent = ThemeRGB(hex: 0xF54E00); $0.accent2 = ThemeRGB(hex: 0x34785C)
        $0.accentText = ThemeRGB(hex: 0xC23E00)
        $0.success = ThemeRGB(hex: 0x34785C); $0.danger = ThemeRGB(hex: 0xCF2D56); $0.warning = ThemeRGB(hex: 0x8F6118)
        $0.actionWarm = ThemeRGB(hex: 0xC08532); $0.actionPositive = ThemeRGB(hex: 0x34785C)
        $0.diffAdded = $0.surface.mixed(with: $0.success, 0.13); $0.diffRemoved = $0.surface.mixed(with: $0.danger, 0.11)
        $0.setSyntax(keyword: 0x1F7A6A, string: 0xB8407C, comment: 0x8A8A8A, number: 0x8A6A1A, type: 0x1F5FA8, function: 0xB35A1F, property: 0x6A4FB8)
        $0.onAccent = ThemeRGB(hex: 0xF7F7F4)
        $0.outline = ThemeRGB(hex: 0xCDCDC9)
        $0.selection = ThemeRGB(hex: 0x8BC4F8)
        $0.secondaryTextColor = ThemeRGB(hex: 0x6B6A63); $0.tertiaryTextColor = ThemeRGB(hex: 0xA1A19F)
        $0.style = ThemeStyle(strokeScale: 0.75, allowsGlass: false, radiusSet: .paper, primaryButton: .accent, selectionTint: .accent, flatCards: true)
    })

    /// 纸感暖墨(深色):以 Ink 为卡片色,暖色提亮满足对比度(由同一规则推导)。
    static let paperDark = ThemePackage(id: "paper-dark", name: String(localized: "Cursor 纸感 · 暖墨"), group: .paper, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x1B1A16, card: 0x26251E, gutter: 0x1F1E19, currentLine: 0x2E2D25, sidebar: 0x15140F)
        $0.editorForeground = ThemeRGB(hex: 0xF2F1ED); $0.gutterForeground = ThemeRGB(hex: 0x7A7974)
        $0.accent = ThemeRGB(hex: 0xFF7A3D); $0.accent2 = ThemeRGB(hex: 0x5FB48F)
        $0.success = ThemeRGB(hex: 0x5FB48F); $0.danger = ThemeRGB(hex: 0xFF6F8E); $0.warning = ThemeRGB(hex: 0xDDA24A)
        $0.actionWarm = ThemeRGB(hex: 0xC08532); $0.actionPositive = ThemeRGB(hex: 0x34785C)
        $0.diffAdded = $0.surface.mixed(with: $0.success, 0.16); $0.diffRemoved = $0.surface.mixed(with: $0.danger, 0.16)
        $0.setSyntax(keyword: 0x83D6C5, string: 0xE394DC, comment: 0x7A7974, number: 0xEBC88D, type: 0x87C3FF, function: 0xEFB080, property: 0xAAA0FA)
        $0.onAccent = ThemeRGB(hex: 0x1B1A16)
        $0.outline = ThemeRGB(hex: 0x3F3E36)
        $0.selection = ThemeRGB(hex: 0x8BC4F8)
        $0.style = ThemeStyle(strokeScale: 0.75, allowsGlass: false, radiusSet: .paper, primaryButton: .accent, selectionTint: .accent, flatCards: true)
    })

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

    // 经典配色:每套都带独立的圆角/描边/阴影风格
    static let nord = ThemePackage(id: "nord", name: "Nord", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x2E3440, card: 0x3B4252, gutter: 0x2B303B, currentLine: 0x3B4252, sidebar: 0x272C36)
        $0.editorForeground = ThemeRGB(hex: 0xE5E9F0); $0.gutterForeground = ThemeRGB(hex: 0x6B7790)
        $0.accent = ThemeRGB(hex: 0x88C0D0); $0.accent2 = ThemeRGB(hex: 0xB48EAD)
        $0.success = ThemeRGB(hex: 0xA3BE8C); $0.danger = ThemeRGB(hex: 0xBF616A); $0.warning = ThemeRGB(hex: 0xEBCB8B)
        $0.diffAdded = ThemeRGB(hex: 0x33473A); $0.diffRemoved = ThemeRGB(hex: 0x4A3338)
        $0.setSyntax(keyword: 0x81A1C1, string: 0xA3BE8C, comment: 0x7B88A1, number: 0xB48EAD, type: 0x8FBCBB, function: 0x88C0D0, property: 0xD8DEE9)
        $0.style = ThemeStyle(cornerScale: 0.9, strokeScale: 0.8, shadowScale: 0.8)
    })

    static let solarizedDark = ThemePackage(id: "solarized-dark", name: "Solarized Dark", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x002B36, card: 0x073642, gutter: 0x01313C, currentLine: 0x0B3C49, sidebar: 0x00222B)
        $0.editorForeground = ThemeRGB(hex: 0xD5DDDD); $0.gutterForeground = ThemeRGB(hex: 0x586E75)
        $0.accent = ThemeRGB(hex: 0x2AA198); $0.accent2 = ThemeRGB(hex: 0x6C71C4)
        $0.success = ThemeRGB(hex: 0x859900); $0.danger = ThemeRGB(hex: 0xDC322F); $0.warning = ThemeRGB(hex: 0xB58900)
        $0.diffAdded = ThemeRGB(hex: 0x0B4A35); $0.diffRemoved = ThemeRGB(hex: 0x4A2229)
        $0.setSyntax(keyword: 0x859900, string: 0x2AA198, comment: 0x6C8790, number: 0xD33682, type: 0xB58900, function: 0x268BD2, property: 0x93A1A1)
        $0.style = ThemeStyle(cornerScale: 0.8, strokeScale: 1.2, shadowScale: 0.6)
    })

    static let solarizedLight = ThemePackage(id: "solarized-light", name: "Solarized Light", group: .classic, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFDF6E3, card: 0xF5EDD6, gutter: 0xF3EBD3, currentLine: 0xEEE8D5, sidebar: 0xEEE8D5)
        $0.editorForeground = ThemeRGB(hex: 0x30454D); $0.gutterForeground = ThemeRGB(hex: 0x93A1A1)
        $0.accent = ThemeRGB(hex: 0x1E8A82); $0.accent2 = ThemeRGB(hex: 0x6C71C4)
        $0.success = ThemeRGB(hex: 0x667700); $0.danger = ThemeRGB(hex: 0xCB2F2D); $0.warning = ThemeRGB(hex: 0x946C00)
        $0.diffAdded = ThemeRGB(hex: 0xE3EBC7); $0.diffRemoved = ThemeRGB(hex: 0xF7DDD3)
        $0.setSyntax(keyword: 0x667700, string: 0x1E8A82, comment: 0x7C8F94, number: 0xC22C74, type: 0x946C00, function: 0x1F78B8, property: 0x586E75)
        $0.style = ThemeStyle(cornerScale: 0.8, strokeScale: 1.2, shadowScale: 0.6)
    })

    static let dracula = ThemePackage(id: "dracula", name: "Dracula", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x282A36, card: 0x343746, gutter: 0x2C2E3B, currentLine: 0x3A3D4F, sidebar: 0x21222C)
        $0.editorForeground = ThemeRGB(hex: 0xF8F8F2); $0.gutterForeground = ThemeRGB(hex: 0x6D7399)
        $0.accent = ThemeRGB(hex: 0xBD93F9); $0.accent2 = ThemeRGB(hex: 0xFF79C6)
        $0.success = ThemeRGB(hex: 0x50FA7B); $0.danger = ThemeRGB(hex: 0xFF5555); $0.warning = ThemeRGB(hex: 0xFFB86C)
        $0.diffAdded = ThemeRGB(hex: 0x1F4A33); $0.diffRemoved = ThemeRGB(hex: 0x57262E)
        $0.setSyntax(keyword: 0xFF79C6, string: 0xF1FA8C, comment: 0x7C89BD, number: 0xBD93F9, type: 0x8BE9FD, function: 0x50FA7B, property: 0xFFB86C)
        $0.style = ThemeStyle(cornerScale: 1.25, strokeScale: 0.9, shadowScale: 1.2, glassTint: 0.08)
    })

    static let tokyoNight = ThemePackage(id: "tokyo-night", name: "Tokyo Night", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x1A1B26, card: 0x24283B, gutter: 0x1E202E, currentLine: 0x292E42, sidebar: 0x16161E)
        $0.editorForeground = ThemeRGB(hex: 0xC8D0F7); $0.gutterForeground = ThemeRGB(hex: 0x565F89)
        $0.accent = ThemeRGB(hex: 0x7AA2F7); $0.accent2 = ThemeRGB(hex: 0xBB9AF7)
        $0.success = ThemeRGB(hex: 0x9ECE6A); $0.danger = ThemeRGB(hex: 0xF7768E); $0.warning = ThemeRGB(hex: 0xE0AF68)
        $0.diffAdded = ThemeRGB(hex: 0x1F3A2C); $0.diffRemoved = ThemeRGB(hex: 0x472631)
        $0.setSyntax(keyword: 0xBB9AF7, string: 0x9ECE6A, comment: 0x6F7AA6, number: 0xFF9E64, type: 0x2AC3DE, function: 0x7AA2F7, property: 0x73DACA)
        $0.style = ThemeStyle(cornerScale: 1.1, strokeScale: 0.9, shadowScale: 1.1, glassTint: 0.05)
    })

    static let githubLight = ThemePackage(id: "github-light", name: "GitHub Light", group: .classic, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFFFFFF, card: 0xF6F8FA, gutter: 0xF6F8FA, currentLine: 0xEAF1FB, sidebar: 0xF6F8FA)
        $0.editorForeground = ThemeRGB(hex: 0x1F2328); $0.gutterForeground = ThemeRGB(hex: 0x8C959F)
        $0.accent = ThemeRGB(hex: 0x0969DA); $0.accent2 = ThemeRGB(hex: 0x8250DF)
        $0.success = ThemeRGB(hex: 0x1A7F37); $0.danger = ThemeRGB(hex: 0xCF222E); $0.warning = ThemeRGB(hex: 0x9A6700)
        $0.diffAdded = ThemeRGB(hex: 0xDAFBE1); $0.diffRemoved = ThemeRGB(hex: 0xFFEBE9)
        $0.setSyntax(keyword: 0xCF222E, string: 0x0A3069, comment: 0x6E7781, number: 0x0550AE, type: 0x953800, function: 0x8250DF, property: 0x0550AE)
        $0.style = ThemeStyle(cornerScale: 0.75, strokeScale: 1.4, shadowScale: 0.6)
    })

    static let githubDark = ThemePackage(id: "github-dark", name: "GitHub Dark", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x0D1117, card: 0x161B22, gutter: 0x0D1117, currentLine: 0x1B2330, sidebar: 0x010409)
        $0.editorForeground = ThemeRGB(hex: 0xE6EDF3); $0.gutterForeground = ThemeRGB(hex: 0x6E7681)
        $0.accent = ThemeRGB(hex: 0x58A6FF); $0.accent2 = ThemeRGB(hex: 0xBC8CFF)
        $0.success = ThemeRGB(hex: 0x3FB950); $0.danger = ThemeRGB(hex: 0xF85149); $0.warning = ThemeRGB(hex: 0xD29922)
        $0.diffAdded = ThemeRGB(hex: 0x12361E); $0.diffRemoved = ThemeRGB(hex: 0x4A1E21)
        $0.setSyntax(keyword: 0xFF7B72, string: 0xA5D6FF, comment: 0x8B949E, number: 0x79C0FF, type: 0xFFA657, function: 0xD2A8FF, property: 0x79C0FF)
        $0.style = ThemeStyle(cornerScale: 0.75, strokeScale: 1.4, shadowScale: 0.6)
    })

    static let gruvboxDark = ThemePackage(id: "gruvbox-dark", name: "Gruvbox Dark", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x282828, card: 0x32302F, gutter: 0x2B2A29, currentLine: 0x3C3836, sidebar: 0x1D2021)
        $0.editorForeground = ThemeRGB(hex: 0xEBDBB2); $0.gutterForeground = ThemeRGB(hex: 0x7C6F64)
        $0.accent = ThemeRGB(hex: 0xFE8019); $0.accent2 = ThemeRGB(hex: 0xD3869B)
        $0.success = ThemeRGB(hex: 0xB8BB26); $0.danger = ThemeRGB(hex: 0xFB4934); $0.warning = ThemeRGB(hex: 0xFABD2F)
        $0.diffAdded = ThemeRGB(hex: 0x3A3D1C); $0.diffRemoved = ThemeRGB(hex: 0x4F2420)
        $0.setSyntax(keyword: 0xFB4934, string: 0xB8BB26, comment: 0xA09484, number: 0xD3869B, type: 0xFABD2F, function: 0x83A598, property: 0x8EC07C)
        $0.style = ThemeStyle(cornerScale: 0.6, strokeScale: 1.2, shadowScale: 0.5)
    })

    static let catppuccinMocha = ThemePackage(id: "catppuccin-mocha", name: "Catppuccin Mocha", group: .classic, tone: .dark, palette: .make(.darkBase) {
        $0.setBackgrounds(surface: 0x1E1E2E, card: 0x313244, gutter: 0x232334, currentLine: 0x2A2B3C, sidebar: 0x181825)
        $0.editorForeground = ThemeRGB(hex: 0xCDD6F4); $0.gutterForeground = ThemeRGB(hex: 0x6C7086)
        $0.accent = ThemeRGB(hex: 0xCBA6F7); $0.accent2 = ThemeRGB(hex: 0xF5C2E7)
        $0.success = ThemeRGB(hex: 0xA6E3A1); $0.danger = ThemeRGB(hex: 0xF38BA8); $0.warning = ThemeRGB(hex: 0xF9E2AF)
        $0.diffAdded = ThemeRGB(hex: 0x27402E); $0.diffRemoved = ThemeRGB(hex: 0x4B2735)
        $0.setSyntax(keyword: 0xCBA6F7, string: 0xA6E3A1, comment: 0x8F94AF, number: 0xFAB387, type: 0xF9E2AF, function: 0x89B4FA, property: 0x94E2D5)
        $0.style = ThemeStyle(cornerScale: 1.35, strokeScale: 0.8, shadowScale: 1.2, glassTint: 0.1, fillScale: 1.2)
    })

    static let monoInk = ThemePackage(id: "mono-ink", name: String(localized: "墨色单色"), group: .classic, tone: .light, palette: .make(.lightBase) {
        $0.setBackgrounds(surface: 0xFAFAFA, card: 0xF0F0F0, gutter: 0xF3F3F3, currentLine: 0xEBEBEB, sidebar: 0xECECEC)
        $0.editorForeground = ThemeRGB(hex: 0x111111); $0.gutterForeground = ThemeRGB(hex: 0x9A9A9A)
        $0.accent = ThemeRGB(hex: 0x1A1A1A); $0.accent2 = ThemeRGB(hex: 0x5A5A5A)
        $0.success = ThemeRGB(hex: 0x2F6F3E); $0.danger = ThemeRGB(hex: 0xB3261E); $0.warning = ThemeRGB(hex: 0x8A5A00)
        $0.diffAdded = ThemeRGB(hex: 0xE4EEE6); $0.diffRemoved = ThemeRGB(hex: 0xF2E3E1)
        $0.setSyntax(keyword: 0x111111, string: 0x4A4A4A, comment: 0x8A8A8A, number: 0x333333, type: 0x2B2B2B, function: 0x000000, property: 0x555555)
        $0.style = ThemeStyle(cornerScale: 0.4, strokeScale: 1.6, shadowScale: 0.3)
    })

    /// 内置主题(不含用户自定义)。
    public static let builtin: [ThemePackage] = [
        system,
        paperLight, paperDark,
        cursorLight, cursorLightColorblind, cursorDark, cursorDarkHC,
        anthropicLight, anthropicDark,
        claudeDark, claudeLight, claudeDarkDaltonized, claudeLightDaltonized, claudeDarkANSI, claudeLightANSI,
        opencodeDark, opencodeLight,
        nord, solarizedDark, solarizedLight, dracula, tokyoNight, githubLight, githubDark, gruvboxDark, catppuccinMocha, monoInk,
    ]

    /// 全部主题:内置 + 用户自定义(设置页按分组展示)。
    public static var all: [ThemePackage] { builtin + ThemeRuntime.customThemes }

    /// 默认主题 id(Cursor 纸感浅色)。
    public static let defaultID = "paper-light"

    /// 按 id 查找,未知回退系统。
    public static func find(_ id: String) -> ThemePackage { all.first { $0.id == id } ?? .system }
}

// MARK: - 运行时

/// 主题变更追踪器:`ThemeRuntime` 的每次读取都会登记对它的依赖,
/// 因此任何读取 `OMColors`/`OMMetrics` 令牌的 SwiftUI 视图在主题切换时都会自动刷新,无需手动 `.id`。
@Observable
public final class ThemeTracker: @unchecked Sendable {
    public static let shared = ThemeTracker()
    /// 每次主题/强调色变化递增。
    public var revision = 0
    private init() {}
}

/// 当前主题与强调色覆盖(由 `AppearanceModel` 写入;只在主线程的界面刷新周期读取)。
public enum ThemeRuntime {
    /// 运行时配置代号:主题包或强调色覆盖被直接改写时自增,令 `ResolvedTokens` 缓存失效
    /// (正常路径经 `bump()` 递增修订号;测试与启动期直接赋值时靠它保证不读到旧令牌)。
    nonisolated(unsafe) public private(set) static var generation = 0
    nonisolated(unsafe) public static var package: ThemePackage = .system { didSet { generation &+= 1 } }
    /// 用户自定义主题(由 `CustomThemeStore` 加载后写入,只在主线程变更)
    nonisolated(unsafe) public static var customThemes: [ThemePackage] = []
    /// 用户选择的主强调色(nil = 跟随主题默认)
    nonisolated(unsafe) public static var accentOverride: ThemeRGB? { didSet { generation &+= 1 } }
    /// 用户选择的第二强调色(nil = 跟随主题默认)
    nonisolated(unsafe) public static var accent2Override: ThemeRGB? { didSet { generation &+= 1 } }

    /// 系统主题下当前是否深色(由 `AppearanceModel` 在外观变化时更新;供非主线程的令牌读取)。
    nonisolated(unsafe) public static var systemIsDark = false
    /// Diff 是否使用主题配色(关闭后用与主题无关的固定红绿);由外观设置写入。
    nonisolated(unsafe) public static var themedDiff = true

    /// 当前调色板(系统主题为 nil)。读取会登记 Observation 依赖。
    public static var palette: ThemePalette? {
        _ = ThemeTracker.shared.revision
        return package.palette
    }

    /// 当前主题风格。
    public static var style: ThemeStyle { palette?.style ?? .standard }

    /// 生效的主强调色;nil 表示使用系统强调色。
    public static var accent: ThemeRGB? { _ = ThemeTracker.shared.revision; return accentOverride ?? package.palette?.accent }
    /// 生效的第二强调色;nil 表示回退为系统强调色。
    public static var accent2: ThemeRGB? { _ = ThemeTracker.shared.revision; return accent2Override ?? package.palette?.accent2 }

    /// 主题变化通知(编辑器据此重新应用配色、清空高亮缓存)。
    public static let didChange = Notification.Name("OMThemeDidChange")

    /// 通知所有依赖令牌的视图刷新(只应由 `AppearanceModel` 调用)。
    @MainActor public static func bump() {
        ThemeTracker.shared.revision += 1
    }
}
