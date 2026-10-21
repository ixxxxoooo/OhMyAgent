// @author ixxxxoooo
// 记住用户手动选择的权限模式(Auto / 计划 / 接受编辑等):按 Agent 保存,新开会话时自动沿用,不必每次重选。

import ACPKit
import Foundation

/// 权限模式偏好的存取与选择逻辑(纯函数,便于测试)。
public enum PreferredMode {
    /// 偏好在 UserDefaults 里的键。
    /// - Parameter agentId: Agent 标识
    /// - Returns: 键名(`chat.` 前缀,随「重置偏好」一并清除)
    static func key(agentId: String) -> String { "chat.preferredMode.\(agentId)" }

    /// 读取已保存的模式。
    /// - Parameters:
    ///   - agentId: Agent 标识
    ///   - defaults: 偏好存储
    /// - Returns: 模式值;未保存为 nil
    public static func saved(agentId: String, _ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(agentId: agentId))
    }

    /// 保存模式。
    /// - Parameters:
    ///   - value: 模式值;空串视为清除
    ///   - agentId: Agent 标识
    ///   - defaults: 偏好存储
    public static func save(_ value: String, agentId: String, _ defaults: UserDefaults = .standard) {
        guard !agentId.isEmpty else { return }
        if value.isEmpty { defaults.removeObject(forKey: key(agentId: agentId)) } else { defaults.set(value, forKey: key(agentId: agentId)) }
    }

    /// 计算新会话需要切换到的模式。
    /// - Parameters:
    ///   - saved: 已保存的模式
    ///   - option: 会话当前的模式配置项
    /// - Returns: 需要切换到的值;无偏好、已是该值或该 Agent 不支持该值时为 nil
    public static func target(saved: String?, option: SessionConfigOption?) -> String? {
        guard let saved, !saved.isEmpty, let option else { return nil }
        guard option.options.contains(where: { $0.value == saved }) else { return nil }
        return option.currentValue.stringValue == saved ? nil : saved
    }
}

extension SessionModel {
    /// 新建会话后,把权限模式、模型、思考强度切换到用户上次选择的值(恢复历史会话不调用)。
    /// 各项按顺序逐个应用:每次响应都带回完整配置列表,并发提交会让先返回的结果被后返回的旧列表覆盖。
    func applyPreferredMode() {
        if isHibernated { whenAwake { [weak self] in self?.applyPreferredMode() }; return }
        let changes = PreferredConfigOption.changes(agentId: activeDescriptor.id, options: configOptions)
        guard !changes.isEmpty, let client, let sessionId else { return }
        Task { [weak self] in
            for change in changes {
                guard self?.sessionId == sessionId else { return }
                do {
                    let updated = try await client.setConfigOption(sessionId: sessionId, configId: change.optionId, value: .string(change.value))
                    if !updated.isEmpty { self?.configOptions = updated }
                } catch {
                    self?.log.warning("沿用上次选择失败", ["option": change.optionId, "error": "\(error)"])
                }
            }
        }
    }
}
