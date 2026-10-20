// @author ixxxxoooo
// 设置读取:合并 `~/.claude/settings.json`、项目 `.claude/settings.json`、`settings.local.json` 与受管设置,
// 供模型/权限模式/思考强度的初始值判定。只读,不写回。

import ACPKit
import Foundation
import OMLog

/// 合并后的 Claude 设置(只关心适配器用到的字段)。
public struct ClaudeSettings: Sendable, Equatable {
    public var raw: [String: JSONValue] = [:]
    /// 受管设置里的禁用模型
    public var managedDeniedModels: [String] = []
    /// 受管设置指定的 apiKeyHelper(存在即视为受管凭据)
    public var managedApiKeyHelper: String?

    public var model: String? { raw["model"]?.stringValue }
    public var availableModels: [String]? { raw["availableModels"]?.arrayValue?.compactMap(\.stringValue) }
    public var modelOverrides: [String: String] {
        (raw["modelOverrides"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
    public var defaultMode: JSONValue? { raw["permissions"]?["defaultMode"] }
    public var bypassDisabled: Bool { raw["permissions"]?["disableBypassPermissionsMode"]?.stringValue == "disable" }
    public var effortLevel: String? { raw["effortLevel"]?.stringValue }
    public var ultracode: Bool { raw["ultracode"]?.boolValue == true }
    public var modelSettings: [String: JSONValue] { raw["modelSettings"]?.objectValue ?? [:] }
}

/// 设置读取器。
public struct SettingsStore: Sendable {
    public let configDirectory: URL
    public let managedPath: String

    /// - Parameters:
    ///   - configDirectory: Claude 配置目录
    ///   - managedPath: 受管设置路径(测试可覆盖)
    public init(configDirectory: URL, managedPath: String = "/Library/Application Support/ClaudeCode/managed-settings.json") {
        self.configDirectory = configDirectory
        self.managedPath = managedPath
    }

    /// 读取并合并设置(优先级:受管 > 项目本地 > 项目 > 用户)。
    /// - Parameter cwd: 项目工作目录
    public func load(cwd: String) -> ClaudeSettings {
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        let layers = [
            configDirectory.appendingPathComponent("settings.json"),
            project.appendingPathComponent("settings.json"),
            project.appendingPathComponent("settings.local.json"),
        ]
        var merged: [String: JSONValue] = [:]
        for url in layers { merged = Self.merge(merged, Self.read(url)) }
        var settings = ClaudeSettings()
        let managed = Self.read(URL(fileURLWithPath: managedPath))
        settings.managedDeniedModels = (managed["deniedModels"]?.arrayValue ?? []).compactMap(\.stringValue)
        settings.managedApiKeyHelper = managed["apiKeyHelper"]?.nonEmptyString
        merged = Self.merge(merged, managed)
        settings.raw = merged
        return settings
    }

    private static func read(_ url: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let value = JSONValue.parse(data)?.objectValue else {
            Log.agent.warning("设置文件解析失败,已忽略", ["path": url.path])
            return [:]
        }
        return value
    }

    /// 对象递归合并,数组与标量以后者为准。
    static func merge(_ base: [String: JSONValue], _ overlay: [String: JSONValue]) -> [String: JSONValue] {
        var result = base
        for (key, value) in overlay {
            if let existing = result[key]?.objectValue, let incoming = value.objectValue {
                result[key] = .object(merge(existing, incoming))
            } else {
                result[key] = value
            }
        }
        return result
    }
}
