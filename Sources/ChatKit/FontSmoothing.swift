// @author ixxxxoooo
// 字体平滑偏好:映射到 macOS 的 `AppleFontSmoothing` 默认值(0 关闭 / 1 轻 / 2 中 / 3 强)。
// 该键只写入本应用的偏好域(不影响其他应用),须在创建任何窗口前应用,修改后重启生效。

import Foundation

/// 字体平滑档位。
public enum FontSmoothing: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统(不写入键,使用系统全局设置)
    case system
    /// 关闭:笔画最细
    case off
    /// 轻
    case light
    /// 中
    case medium
    /// 强:笔画最粗
    case strong

    public var id: String { rawValue }

    /// 偏好键(UserDefaults 与设置页 `@AppStorage` 同名)。
    public static let preferenceKey = "appearance.fontSmoothing"
    /// macOS 读取的默认值键。
    public static let appleKey = "AppleFontSmoothing"

    /// 写入 `AppleFontSmoothing` 的整数值;「跟随系统」为 nil(移除键)。
    public var appleValue: Int? {
        switch self {
        case .system: return nil
        case .off: return 0
        case .light: return 1
        case .medium: return 2
        case .strong: return 3
        }
    }

    /// 设置页显示名(中文开发语言,键即原文)。
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .off: return "关闭(最细)"
        case .light: return "轻"
        case .medium: return "中"
        case .strong: return "强(最粗)"
        }
    }

    /// 读取当前偏好;非法值回退「跟随系统」。
    /// - Parameter defaults: 偏好存储
    public static func current(_ defaults: UserDefaults = .standard) -> FontSmoothing {
        FontSmoothing(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    /// 把当前偏好应用到本应用的 `AppleFontSmoothing`;须早于任何文本控件创建。
    /// - Parameter defaults: 偏好存储
    public static func applyAtLaunch(_ defaults: UserDefaults = .standard) {
        if let value = current(defaults).appleValue {
            defaults.set(value, forKey: appleKey)
        } else {
            defaults.removeObject(forKey: appleKey)
        }
    }
}
