// @author ixxxxoooo
// 滚动条显示方式:跟随系统(默认)/ 自动隐藏 / 始终显示。纯逻辑(无视图),在「设置 → 外观」里切换。

import Foundation

/// 滚动条显示方式。
public enum ScrollbarVisibility: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统「显示滚动条」设置(默认)
    case system
    /// 自动隐藏:仅在滚动时出现(浮层样式)
    case autoHide
    /// 始终显示
    case always

    public var id: String { rawValue }

    /// 显示名(中文原文,同时是本地化键)。
    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .autoHide: "自动隐藏"
        case .always: "始终显示"
        }
    }

    /// 解析存储值,无法识别时回退为跟随系统。
    /// - Parameter raw: 存储的原始字符串
    public static func resolve(_ raw: String?) -> ScrollbarVisibility {
        raw.flatMap(ScrollbarVisibility.init(rawValue:)) ?? .system
    }

    /// 从偏好读取当前设置。
    /// - Parameter defaults: 偏好存储
    public static func current(_ defaults: UserDefaults = .standard) -> ScrollbarVisibility {
        resolve(defaults.string(forKey: ClientPrefs.Key.scrollbarVisibility))
    }
}
