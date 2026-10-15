// @author ygw
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
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 强调色。
public enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case system, blue, purple, pink, orange, green, graphite
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "系统"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .orange: return "橙色"
        case .green: return "绿色"
        case .graphite: return "石墨"
        }
    }
    /// 对应颜色;`system` 返回 nil 表示使用系统强调色。
    public var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .graphite: return .gray
        }
    }
}

/// 外观偏好模型。
@MainActor
@Observable
public final class AppearanceModel {
    public static let shared = AppearanceModel()

    public var theme: AppTheme { didSet { save("theme", theme.rawValue); applyTheme() } }
    public var accent: AccentChoice { didSet { save("accent", accent.rawValue) } }
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

    private static let prefix = "appearance."
    private var isLoading = true

    private init() {
        let defaults = UserDefaults.standard
        func string(_ key: String) -> String? { defaults.string(forKey: Self.prefix + key) }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: Self.prefix + key) as? Double ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        theme = AppTheme(rawValue: string("theme") ?? "") ?? .system
        accent = AccentChoice(rawValue: string("accent") ?? "") ?? .system
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
        theme = .system; accent = .system; uiFontScale = 1; timelineFontScale = 1
        isCompact = false; reduceMotion = false; alwaysOpaque = false; fallbackOnLowPower = true
    }

    /// 应用全部设置(启动时调用)。
    public func applyAll() {
        applyTheme()
        applyScale()
        MaterialPolicy.shared.preference = alwaysOpaque ? .alwaysOpaque : .system
        MaterialPolicy.shared.fallbackOnLowPower = fallbackOnLowPower
    }

    private func applyTheme() {
        switch theme {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
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
