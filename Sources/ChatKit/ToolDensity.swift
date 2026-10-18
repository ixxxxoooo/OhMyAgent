// @author ixxxxoooo
// 工具调用详细程度(会话流里工具行的信息量):精简 / 标准 / 详细。
// (无论哪一档,回合结束后整段过程都会折叠成「已工作 12分8秒」一行,展开后再按所选档位呈现。)
// 精简:连续的工具调用折叠为一行摘要;标准:每个工具一行(浏览类连续步骤合并);详细:每行下方带内联预览。

import Foundation

/// 工具调用详细程度。
public enum ToolDensity: String, CaseIterable, Identifiable, Sendable {
    /// 精简:相邻工具合并为一行摘要
    case compact
    /// 标准:每个工具一行
    case standard
    /// 详细:每行下方内联预览(Diff / 命令输出)
    case detailed

    public var id: String { rawValue }

    /// 偏好键(UserDefaults 与设置页 `@AppStorage` 同名)。
    public static let preferenceKey = "chat.toolDensity"

    /// 档位显示名(中文原文,即本地化键)。
    public var title: String {
        switch self {
        case .compact: return "精简"
        case .standard: return "标准"
        case .detailed: return "详细"
        }
    }

    /// 读取当前偏好;缺省或非法值为「标准」。
    /// - Parameter defaults: 偏好存储
    public static func current(_ defaults: UserDefaults = .standard) -> ToolDensity {
        ToolDensity(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .standard
    }
}
