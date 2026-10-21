// @author ixxxxoooo
// 记住用户手动选择的会话配置(权限模式、模型、思考强度)与引擎:新建会话/新窗口时自动沿用,不必每次重选。
// 配置按 Agent 保存(各引擎的选项值不通用);引擎偏好全局唯一。键统一 `chat.` 前缀,随「重置偏好」一并清除。

import ACPKit
import Foundation

/// 一次待应用的配置切换。
public struct PreferredConfigChange: Sendable, Equatable {
    /// 配置项 ID
    public let optionId: String
    /// 目标值
    public let value: String
}

/// 会话配置偏好(模式 / 模型 / 思考强度)的存取与选择逻辑(纯函数,便于测试)。
public enum PreferredConfigOption {
    /// 参与「记住」的配置项类别,按此顺序应用。
    static let categories = ["mode", "model", "thought_level"]

    /// 偏好在 UserDefaults 里的键;权限模式沿用旧键以保持兼容。
    /// - Parameters:
    ///   - category: 配置项类别
    ///   - agentId: Agent 标识
    /// - Returns: 键名
    static func key(category: String, agentId: String) -> String {
        category == "mode" ? PreferredMode.key(agentId: agentId) : "chat.preferred.\(category).\(agentId)"
    }

    /// 读取已保存的值。
    /// - Parameters:
    ///   - category: 配置项类别
    ///   - agentId: Agent 标识
    ///   - defaults: 偏好存储
    /// - Returns: 已保存的值;未保存为 nil
    public static func saved(category: String, agentId: String, _ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(category: category, agentId: agentId))
    }

    /// 保存用户选择;不在 `categories` 内的类别、空 Agent 标识会被忽略,空值视为清除。
    /// - Parameters:
    ///   - value: 选项值
    ///   - category: 配置项类别
    ///   - agentId: Agent 标识
    ///   - defaults: 偏好存储
    public static func save(_ value: String, category: String, agentId: String, _ defaults: UserDefaults = .standard) {
        guard categories.contains(category), !agentId.isEmpty else { return }
        let storageKey = key(category: category, agentId: agentId)
        if value.isEmpty { defaults.removeObject(forKey: storageKey) } else { defaults.set(value, forKey: storageKey) }
    }

    /// 计算新会话需要应用的全部切换(已是目标值、该 Agent 不支持该值的项会被略过)。
    /// - Parameters:
    ///   - agentId: Agent 标识
    ///   - options: 会话当前的配置项
    ///   - defaults: 偏好存储
    /// - Returns: 按类别顺序排列的切换列表
    public static func changes(agentId: String, options: [SessionConfigOption], _ defaults: UserDefaults = .standard) -> [PreferredConfigChange] {
        categories.compactMap { category in
            guard let option = options.first(where: { $0.category == category }),
                  let value = PreferredMode.target(saved: saved(category: category, agentId: agentId, defaults), option: option) else { return nil }
            return PreferredConfigChange(optionId: option.id, value: value)
        }
    }
}

/// 引擎(Agent)偏好:记住用户上次手动选择的引擎,新会话默认使用它。
public enum PreferredEngine {
    /// 偏好在 UserDefaults 里的键。
    static let key = "chat.lastAgent"

    /// 读取上次选择的引擎。
    /// - Parameter defaults: 偏好存储
    /// - Returns: Agent ID;未保存为 nil
    public static func saved(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    /// 保存引擎选择;空 ID 视为清除。
    /// - Parameters:
    ///   - agentId: Agent ID
    ///   - defaults: 偏好存储
    public static func save(_ agentId: String, _ defaults: UserDefaults = .standard) {
        if agentId.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(agentId, forKey: key) }
    }

    /// 清除记住的引擎(用户在设置里明确指定默认 Agent 时调用,使其立即生效)。
    /// - Parameter defaults: 偏好存储
    public static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
