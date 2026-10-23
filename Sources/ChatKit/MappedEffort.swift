// @author ixxxxoooo
// 映射会话的思考强度:网关别名(`oma-*`)对 Claude Code 是未知模型,按模型的强度设置(`modelSettings`)匹配不上,
// 内置默认值也会退到未知模型的 `high`(Claude 4.x/5.x 的 Opus/Sonnet/Haiku 默认是 `medium`),
// 导致同一个模型经映射后思考与输出 token 明显变多。这里把真实模型应得的强度按别名写进会话 settings。

import ACPKit
import Foundation

/// `~/.claude/settings.json` 里与思考强度相关的偏好。
public struct ClaudeEffortPrefs: Sendable, Equatable {
    /// 按模型的设置(键为模型 ID,值为该模型的设置对象,原样保留)
    public var modelSettings: [String: JSONValue]
    /// 全局强度(`effortLevel`);设置了它时不再套用内置默认值,以免盖过用户的全局选择
    public var globalEffort: String?

    /// 创建偏好。
    /// - Parameters:
    ///   - modelSettings: 按模型的设置
    ///   - globalEffort: 全局强度
    public init(modelSettings: [String: JSONValue] = [:], globalEffort: String? = nil) {
        self.modelSettings = modelSettings
        self.globalEffort = globalEffort
    }

    /// 读取用户级设置(读磁盘,请在后台调用;文件缺失或损坏时返回空偏好)。
    /// - Parameter home: 家目录(测试可注入)
    /// - Returns: 强度偏好
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeEffortPrefs {
        let file = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file), let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return ClaudeEffortPrefs() }
        let effort = root["effortLevel"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        return ClaudeEffortPrefs(modelSettings: root["modelSettings"]?.objectValue ?? [:], globalEffort: effort?.isEmpty == false ? effort : nil)
    }

    /// 真实模型在原生 Claude Code 里会得到的强度。
    ///
    /// 优先用户按模型的设置(键大小写不敏感);否则在用户没设全局强度时,对 Claude Opus/Sonnet/Haiku 取 Claude Code 内置默认 `medium`;
    /// 其余模型(第三方、Fable 等)返回 nil,保持 Claude Code 对别名的默认行为。
    /// - Parameter model: 发给上游的真实模型 ID
    /// - Returns: 强度;无需干预时为 nil
    public func effort(forModel model: String) -> String? {
        let key = model.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let entry = modelSettings.first(where: { $0.key.lowercased() == key }), let level = entry.value["effortLevel"]?.stringValue, !level.isEmpty {
            return level
        }
        guard globalEffort == nil else { return nil }
        return Self.defaultMediumFamilies.contains { key.hasPrefix($0) } ? "medium" : nil
    }

    /// Claude Code 内置默认强度为 `medium` 的模型族(2.1.3xx 实测;未知模型默认 `high`)。
    static let defaultMediumFamilies = ["claude-opus-", "claude-sonnet-", "claude-haiku-"]
}

/// 映射会话的 `modelSettings` 生成。
enum MappedEffort {
    /// 会话 settings 的 `modelSettings`:用户原有的按模型设置 + 每个已映射别名对应真实模型的强度。
    /// - Parameters:
    ///   - mapping: 已解析的映射
    ///   - prefs: 用户强度偏好
    /// - Returns: `modelSettings` 对象;无需写入时为 nil
    static func modelSettings(_ mapping: ResolvedMapping, prefs: ClaudeEffortPrefs) -> JSONValue? {
        // 带上用户原有条目:flag 层的同名对象可能整体覆盖用户层,别让原生模型的设置在映射会话里丢失
        var result = prefs.modelSettings
        for (slot, target) in mapping.all {
            guard let effort = prefs.effort(forModel: target.model) else { continue }
            var entry = result[slot.alias]?.objectValue ?? [:]
            entry["effortLevel"] = .string(effort)
            result[slot.alias] = .object(entry)
        }
        return result.isEmpty ? nil : .object(result)
    }
}
