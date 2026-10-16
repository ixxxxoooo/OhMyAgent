// @author ixxxxoooo
// 外观偏好:主题、强调色、字号、密度、动效与透明度。写入 UserDefaults,修改后立即生效(热更新)。

import AppKit
import Observation
import SwiftUI

/// 主题。
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }
}

/// 强调色预设。`system` 表示「跟随主题」(系统主题时为系统强调色);`custom` 使用自定义十六进制色。
public enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case system, graphite, clay, blue, purple, pink, orange, green, cyan, red, yellow, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return String(localized: "跟随主题")
        case .graphite: return String(localized: "石墨")
        case .clay: return String(localized: "陶土")
        case .blue: return String(localized: "蓝色")
        case .purple: return String(localized: "紫色")
        case .pink: return String(localized: "粉色")
        case .orange: return String(localized: "橙色")
        case .green: return String(localized: "绿色")
        case .cyan: return String(localized: "青色")
        case .red: return String(localized: "红色")
        case .yellow: return String(localized: "黄色")
        case .custom: return String(localized: "自定义")
        }
    }
    /// 预设颜色;`system` 与 `custom` 返回 nil(由调用方决定)。
    public var rgb: ThemeRGB? {
        switch self {
        case .system, .custom: return nil
        case .graphite: return ThemeRGB(hex: 0x5C6370)
        case .clay: return ThemeRGB(hex: 0xD97757)
        case .blue: return ThemeRGB(hex: 0x0A84FF)
        case .purple: return ThemeRGB(hex: 0xAF52DE)
        case .pink: return ThemeRGB(hex: 0xFF4F8B)
        case .orange: return ThemeRGB(hex: 0xF28A1B)
        case .green: return ThemeRGB(hex: 0x30B45A)
        case .cyan: return ThemeRGB(hex: 0x12B5CB)
        case .red: return ThemeRGB(hex: 0xE5484D)
        case .yellow: return ThemeRGB(hex: 0xE8B90C)
        }
    }
    /// 对应颜色;`system`/`custom` 返回 nil。
    public var color: Color? { rgb?.color }

    /// 解析最终颜色:自定义色优先于预设;`system` 返回 nil(跟随主题)。
    public func resolved(customHex: String) -> ThemeRGB? {
        switch self {
        case .system: return nil
        case .custom: return ThemeRGB(hexString: customHex)
        default: return rgb
        }
    }
}

/// 外观偏好模型。
@MainActor
@Observable
public final class AppearanceModel {
    public static let shared = AppearanceModel()

    /// 外观模式(跟随系统/浅/深);仅在主题包为「跟随系统」时生效,其余主题自带明暗。
    public var theme: AppTheme { didSet { save("theme", theme.rawValue); applyTheme() } }
    /// 主题包 id(见 `ThemePackage.all`)。
    public var themeID: String { didSet { save("themePackage", themeID); themeChanged() } }
    /// 主强调色(`system` 跟随主题)。
    public var accent: AccentChoice { didSet { save("accent", accent.rawValue); themeChanged() } }
    /// 自定义主强调色(`#RRGGBB`)。
    public var customAccentHex: String { didSet { save("accentHex", customAccentHex); themeChanged() } }
    /// 第二强调色(链接、次要徽标;`system` 跟随主题)。
    public var accent2: AccentChoice { didSet { save("accent2", accent2.rawValue); themeChanged() } }
    /// 自定义第二强调色(`#RRGGBB`)。
    public var customAccent2Hex: String { didSet { save("accent2Hex", customAccent2Hex); themeChanged() } }
    /// 界面字号缩放(0.85–1.3)
    public var uiFontScale: Double { didSet { save("uiFontScale", uiFontScale); applyScale() } }
    /// 时间线字号缩放(0.85–1.5)
    public var timelineFontScale: Double { didSet { save("timelineFontScale", timelineFontScale); applyScale() } }
    /// 紧凑密度
    public var isCompact: Bool { didSet { save("compact", isCompact) } }
    /// 减弱动效(也会跟随系统"减少动态效果")
    public var reduceMotion: Bool { didSet { save("reduceMotion", reduceMotion) } }
    /// 总是使用不透明材质
    public var alwaysOpaque: Bool { didSet { save("alwaysOpaque", alwaysOpaque); MaterialPolicy.shared.preference = alwaysOpaque ? .alwaysOpaque : .system } }
    /// 低电量模式自动回退不透明材质
    public var fallbackOnLowPower: Bool { didSet { save("fallbackOnLowPower", fallbackOnLowPower); MaterialPolicy.shared.fallbackOnLowPower = fallbackOnLowPower } }
    /// 每次字号变化递增,用于让时间线整体刷新字体。
    public private(set) var fontRevision = 0
    /// 每次主题/强调色变化递增,用于让依赖令牌颜色的视图整体刷新。
    public private(set) var themeRevision = 0

    /// 当前主题包。
    public var themePackage: ThemePackage { ThemePackage.find(themeID) }

    /// 视图刷新键:字号或主题任一变化都会改变。读取它的视图会被 Observation 追踪。
    public var renderKey: String { "\(fontRevision)-\(themeRevision)" }

    /// 全局 tint(跟随生效的强调色)。读取 `themeRevision` 以建立 Observation 依赖。
    public var tint: Color {
        _ = themeRevision
        return ThemeRuntime.accent?.color ?? Color.accentColor
    }

    private static let prefix = "appearance."
    private var isLoading = true

    private init() {
        let defaults = UserDefaults.standard
        func string(_ key: String) -> String? { defaults.string(forKey: Self.prefix + key) }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: Self.prefix + key) as? Double ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        theme = AppTheme(rawValue: string("theme") ?? "") ?? .system
        themeID = string("themePackage") ?? ThemePackage.system.id
        accent = AccentChoice(rawValue: string("accent") ?? "") ?? .system
        customAccentHex = string("accentHex") ?? "#D97757"
        accent2 = AccentChoice(rawValue: string("accent2") ?? "") ?? .system
        customAccent2Hex = string("accent2Hex") ?? "#5769F7"
        uiFontScale = double("uiFontScale", 1)
        timelineFontScale = double("timelineFontScale", 1)
        isCompact = bool("compact", false)
        reduceMotion = bool("reduceMotion", false)
        alwaysOpaque = bool("alwaysOpaque", false)
        fallbackOnLowPower = bool("fallbackOnLowPower", true)
        isLoading = false
        applyAll()
    }

    /// 动画:减弱动效时返回 nil。
    public var animation: Animation? { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15) }

    /// 恢复默认外观。
    public func reset() {
        theme = .system; themeID = ThemePackage.system.id; accent = .system; accent2 = .system
        customAccentHex = "#D97757"; customAccent2Hex = "#5769F7"; uiFontScale = 1; timelineFontScale = 1
        isCompact = false; reduceMotion = false; alwaysOpaque = false; fallbackOnLowPower = true
    }

    /// 应用全部设置(启动时调用)。
    public func applyAll() {
        applyTheme()
        applyScale()
        MaterialPolicy.shared.preference = alwaysOpaque ? .alwaysOpaque : .system
        MaterialPolicy.shared.fallbackOnLowPower = fallbackOnLowPower
    }

    /// 把主题选择同步到运行时令牌,并强制应用明暗。
    private func applyTheme() {
        ThemeRuntime.package = themePackage
        ThemeRuntime.accentOverride = accent.resolved(customHex: customAccentHex)
        ThemeRuntime.accent2Override = accent2.resolved(customHex: customAccent2Hex)
        // 非系统主题自带明暗;系统主题按「外观模式」
        let tone: ThemeTone = themePackage.tone == .system
            ? (theme == .light ? .light : (theme == .dark ? .dark : .system))
            : themePackage.tone
        switch tone {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 主题或强调色变化:刷新运行时、递增修订号并通知编辑器。
    private func themeChanged() {
        guard !isLoading else { return }
        applyTheme()
        themeRevision += 1
        NotificationCenter.default.post(name: ThemeRuntime.didChange, object: nil)
    }

    private func applyScale() {
        OMScale.ui = CGFloat(min(max(uiFontScale, 0.85), 1.3))
        OMScale.timeline = CGFloat(min(max(timelineFontScale, 0.85), 1.5))
        fontRevision += 1
    }

    private func save(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: Self.prefix + key)
    }
}

/// 是否应减弱动效(应用内开关或系统「减弱动态效果」任一开启)。
@MainActor
public func omShouldReduceMotion() -> Bool {
    AppearanceModel.shared.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

/// 遵循「减弱动态效果」的 withAnimation:减弱时直接执行、不产生动画。
/// - Parameters:
///   - animation: 正常情况下使用的动画
///   - body: 状态变更闭包
@MainActor
public func omWithAnimation(_ animation: Animation = .snappy(duration: 0.2), _ body: () -> Void) {
    if omShouldReduceMotion() { body() } else { withAnimation(animation, body) }
}
