// @author ixxxxoooo
// 代码高亮配色:内置配色方案(每套含浅色/深色两个变体)+ 按单项自定义。
// 默认「跟随主题」使用主题自带的语法色;选了方案后,编辑器与聊天代码块都改用该方案,
// 再叠加用户对单个颜色的自定义。方案按当前主题的明暗自动取浅色或深色变体。

import Foundation

/// 语法着色项(与编辑器的 `SyntaxKind` 一一对应)。
public enum SyntaxToken: String, CaseIterable, Sendable, Identifiable {
    case keyword, string, comment, number, type, function, property

    public var id: String { rawValue }

    /// 设置页里显示的名称。
    public var title: String {
        switch self {
        case .keyword: return String(localized: "关键字")
        case .string: return String(localized: "字符串")
        case .comment: return String(localized: "注释")
        case .number: return String(localized: "数字")
        case .type: return String(localized: "类型")
        case .function: return String(localized: "函数")
        case .property: return String(localized: "属性")
        }
    }
}

/// 一套语法色。
public struct SyntaxColors: Sendable, Equatable {
    public var keyword: ThemeRGB
    public var string: ThemeRGB
    public var comment: ThemeRGB
    public var number: ThemeRGB
    public var type: ThemeRGB
    public var function: ThemeRGB
    public var property: ThemeRGB

    /// 按 7 个 `0xRRGGBB` 创建(顺序:关键字、字符串、注释、数字、类型、函数、属性)。
    public init(_ keyword: UInt32, _ string: UInt32, _ comment: UInt32, _ number: UInt32, _ type: UInt32, _ function: UInt32, _ property: UInt32) {
        self.keyword = ThemeRGB(hex: keyword)
        self.string = ThemeRGB(hex: string)
        self.comment = ThemeRGB(hex: comment)
        self.number = ThemeRGB(hex: number)
        self.type = ThemeRGB(hex: type)
        self.function = ThemeRGB(hex: function)
        self.property = ThemeRGB(hex: property)
    }

    /// 取某一项的颜色。
    public subscript(token: SyntaxToken) -> ThemeRGB {
        switch token {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .function: return function
        case .property: return property
        }
    }
}

/// 内置代码高亮配色方案。
public struct SyntaxScheme: Identifiable, Sendable, Equatable {
    /// 「跟随主题」的占位 id。
    public static let followThemeID = "theme"

    public let id: String
    /// 方案名(专有名词,不翻译)
    public let name: String
    public let light: SyntaxColors
    public let dark: SyntaxColors

    /// 按明暗取变体。
    public func colors(dark isDark: Bool) -> SyntaxColors { isDark ? dark : light }

    /// 全部内置方案。
    public static let all: [SyntaxScheme] = [
        SyntaxScheme(id: "github", name: "GitHub",
                     light: SyntaxColors(0xCF222E, 0x0A3069, 0x6E7781, 0x0550AE, 0x953800, 0x8250DF, 0x0550AE),
                     dark: SyntaxColors(0xFF7B72, 0xA5D6FF, 0x8B949E, 0x79C0FF, 0xFFA657, 0xD2A8FF, 0x79C0FF)),
        SyntaxScheme(id: "one", name: "One",
                     light: SyntaxColors(0xA626A4, 0x50A14F, 0xA0A1A7, 0x986801, 0xC18401, 0x4078F2, 0xE45649),
                     dark: SyntaxColors(0xC678DD, 0x98C379, 0x7F848E, 0xD19A66, 0xE5C07B, 0x61AFEF, 0xE06C75)),
        SyntaxScheme(id: "dracula", name: "Dracula",
                     light: SyntaxColors(0xA3144D, 0x846E15, 0x6C664B, 0x644AC9, 0x036A96, 0x14710A, 0xA34D14),
                     dark: SyntaxColors(0xFF79C6, 0xF1FA8C, 0x6272A4, 0xBD93F9, 0x8BE9FD, 0x50FA7B, 0xFFB86C)),
        SyntaxScheme(id: "solarized", name: "Solarized",
                     light: SyntaxColors(0x859900, 0x2AA198, 0x93A1A1, 0xD33682, 0xB58900, 0x268BD2, 0xCB4B16),
                     dark: SyntaxColors(0x859900, 0x2AA198, 0x586E75, 0xD33682, 0xB58900, 0x268BD2, 0xCB4B16)),
        SyntaxScheme(id: "monokai", name: "Monokai",
                     light: SyntaxColors(0xD6246B, 0x8A7D0A, 0x8C8776, 0x7A56D0, 0x1F8FA6, 0x5B8C0A, 0xC26A0A),
                     dark: SyntaxColors(0xF92672, 0xE6DB74, 0x75715E, 0xAE81FF, 0x66D9EF, 0xA6E22E, 0xFD971F)),
        SyntaxScheme(id: "nord", name: "Nord",
                     light: SyntaxColors(0x5E81AC, 0x6F8F55, 0x8C95A8, 0x9E6E9B, 0x4C8A8A, 0x3D8EA6, 0xB8852A),
                     dark: SyntaxColors(0x81A1C1, 0xA3BE8C, 0x616E88, 0xB48EAD, 0x8FBCBB, 0x88C0D0, 0xEBCB8B)),
        SyntaxScheme(id: "tokyo-night", name: "Tokyo Night",
                     light: SyntaxColors(0x7847BD, 0x587539, 0x848CB5, 0xB15C00, 0x007197, 0x2E7DE9, 0x118C74),
                     dark: SyntaxColors(0xBB9AF7, 0x9ECE6A, 0x565F89, 0xFF9E64, 0x2AC3DE, 0x7AA2F7, 0x73DACA)),
        SyntaxScheme(id: "catppuccin", name: "Catppuccin",
                     light: SyntaxColors(0x8839EF, 0x40A02B, 0x8C8FA1, 0xFE640B, 0xDF8E1D, 0x1E66F5, 0x179299),
                     dark: SyntaxColors(0xCBA6F7, 0xA6E3A1, 0x6C7086, 0xFAB387, 0xF9E2AF, 0x89B4FA, 0x94E2D5)),
        SyntaxScheme(id: "gruvbox", name: "Gruvbox",
                     light: SyntaxColors(0x9D0006, 0x79740E, 0x928374, 0x8F3F71, 0xB57614, 0x427B58, 0x076678),
                     dark: SyntaxColors(0xFB4934, 0xB8BB26, 0x928374, 0xD3869B, 0xFABD2F, 0x8EC07C, 0x83A598)),
    ]

    /// 按 id 查找;「跟随主题」或未知 id 返回 nil。
    public static func find(_ id: String) -> SyntaxScheme? { all.first { $0.id == id } }
}

/// 代码高亮偏好的运行时快照(由 `AppearanceModel` 写入,编辑器/代码块读取)。
public enum SyntaxPrefs {
    /// 当前方案 id(`SyntaxScheme.followThemeID` = 跟随主题)
    nonisolated(unsafe) public static var schemeID = SyntaxScheme.followThemeID
    /// 单项自定义:键为 `light.keyword` / `dark.keyword`,值为 `#RRGGBB`
    nonisolated(unsafe) public static var overrides: [String: String] = [:]

    /// 自定义项的存储键。
    public static func overrideKey(_ token: SyntaxToken, dark: Bool) -> String { "\(dark ? "dark" : "light").\(token.rawValue)" }

    /// 某一项在指定明暗下的用户指定颜色:自定义优先,其次是所选方案;都没有(跟随主题且未自定义)返回 nil。
    /// - Parameters:
    ///   - token: 语法项
    ///   - dark: 目标明暗
    /// - Returns: 颜色;nil 表示沿用主题自带的语法色
    public static func color(_ token: SyntaxToken, dark: Bool) -> ThemeRGB? {
        if let hex = overrides[overrideKey(token, dark: dark)], let rgb = ThemeRGB(hexString: hex) { return rgb }
        return SyntaxScheme.find(schemeID)?.colors(dark: dark)[token]
    }

    /// 是否有任何生效的指定(方案或自定义);用于缓存键与快速跳过。
    public static var isActive: Bool { SyntaxScheme.find(schemeID) != nil || !overrides.isEmpty }

    /// 缓存键:方案或自定义变化后,代码高亮缓存立即失效。
    public static var cacheKey: String {
        "\(schemeID)|" + overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}
