// @author ixxxxoooo
// 插件:读取 ~/.claude/plugins 下的安装记录与市场(通道 B,只读),变更通过 `claude plugin` CLI(通道 C)。

import Foundation

/// 已安装插件。
public struct InstalledPlugin: Sendable, Identifiable, Equatable {
    public var id: String { "\(pluginID)#\(scope)" }
    /// `name@marketplace`
    public var pluginID: String
    public var name: String
    public var marketplace: String
    public var scope: String
    public var version: String
    public var installPath: URL
    public var isEnabled: Bool
    public var description: String
    public var author: String
    public var skillCount: Int
    public var agentCount: Int
    public var commandCount: Int
    public var hasHooks: Bool
    public var mcpServerNames: [String]
}

/// 插件市场。
public struct PluginMarketplace: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var source: String
    public var installLocation: String
    public var lastUpdated: String?
}

/// 插件存储。
public struct PluginStore: Sendable {
    public var paths: ClaudePaths

    public init(paths: ClaudePaths) { self.paths = paths }

    /// 读取已安装插件。
    public func installed() -> [InstalledPlugin] {
        guard let object = try? JSONFile(paths.pluginsDirectory.appendingPathComponent("installed_plugins.json")).read(),
              let plugins = object["plugins"] as? [String: Any] else { return [] }
        let settings = SettingsStore(paths: paths)
        var result: [InstalledPlugin] = []
        for (pluginID, records) in plugins {
            let parts = pluginID.split(separator: "@", maxSplits: 1).map(String.init)
            for record in (records as? [[String: Any]]) ?? [] {
                guard let path = record["installPath"] as? String else { continue }
                let install = URL(fileURLWithPath: path)
                let manifest = (try? JSONFile(install.appendingPathComponent(".claude-plugin/plugin.json")).read()) ?? [:]
                let author = (manifest["author"] as? [String: Any])?["name"] as? String ?? manifest["author"] as? String ?? ""
                let enabled = settings.effectiveValue(["enabledPlugins", pluginID]).flatMap { $0.value as? Bool } ?? false
                let mcp = (try? JSONFile(install.appendingPathComponent(".mcp.json")).read()) ?? [:]
                let servers = ((mcp["mcpServers"] as? [String: Any]) ?? (manifest["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted()
                result.append(InstalledPlugin(
                    pluginID: pluginID, name: manifest["name"] as? String ?? parts[0], marketplace: parts.count > 1 ? parts[1] : "",
                    scope: record["scope"] as? String ?? "user", version: record["version"] as? String ?? (manifest["version"] as? String ?? ""),
                    installPath: install, isEnabled: enabled, description: manifest["description"] as? String ?? "", author: author,
                    skillCount: count(install.appendingPathComponent("skills"), directories: true),
                    agentCount: count(install.appendingPathComponent("agents"), directories: false),
                    commandCount: count(install.appendingPathComponent("commands"), directories: false),
                    hasHooks: FileManager.default.fileExists(atPath: install.appendingPathComponent("hooks/hooks.json").path),
                    mcpServerNames: servers))
            }
        }
        return result.sorted { ($0.name, $0.scope) < ($1.name, $1.scope) }
    }

    private func count(_ directory: URL, directories: Bool) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { item in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return directories ? isDirectory : item.pathExtension == "md"
        }.count
    }

    /// 已启用插件的安装目录(名称 → 目录),供 Skills/Agents/Hooks 只读展示。
    public func enabledRoots() -> [String: URL] {
        var roots: [String: URL] = [:]
        for plugin in installed() where plugin.isEnabled { roots[plugin.name] = plugin.installPath }
        return roots
    }

    /// 读取已配置的市场。
    public func marketplaces() -> [PluginMarketplace] {
        guard let object = try? JSONFile(paths.pluginsDirectory.appendingPathComponent("known_marketplaces.json")).read() else { return [] }
        return object.compactMap { name, raw -> PluginMarketplace? in
            guard let entry = raw as? [String: Any] else { return nil }
            let source = entry["source"] as? [String: Any]
            let description = (source?["repo"] as? String) ?? (source?["url"] as? String) ?? (source?["path"] as? String) ?? (source?["source"] as? String) ?? ""
            return PluginMarketplace(name: name, source: description, installLocation: entry["installLocation"] as? String ?? "", lastUpdated: entry["lastUpdated"] as? String)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - CLI 参数(便于测试)

    public static func installArguments(_ plugin: String, scope: String) -> [String] { ["plugin", "install", plugin, "--scope", scope] }
    public static func uninstallArguments(_ plugin: String, scope: String) -> [String] { ["plugin", "uninstall", plugin, "--scope", scope] }
    public static func toggleArguments(_ plugin: String, enable: Bool, scope: String) -> [String] { ["plugin", enable ? "enable" : "disable", plugin, "--scope", scope] }
    public static func updateArguments(_ plugin: String) -> [String] { ["plugin", "update", plugin] }
    public static func marketplaceAddArguments(_ source: String) -> [String] { ["plugin", "marketplace", "add", source] }
    public static func marketplaceRemoveArguments(_ name: String) -> [String] { ["plugin", "marketplace", "remove", name] }
    public static func marketplaceUpdateArguments(_ name: String?) -> [String] { ["plugin", "marketplace", "update"] + (name.map { [$0] } ?? []) }

    /// 校验用户输入的插件标识或市场来源,避免把选项当参数注入。
    public static func validateArgument(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("-") || trimmed.contains(where: { $0.isNewline }) {
            throw ConfigError.invalidValue(String(localized: "输入无效:不能为空,也不能以 - 开头"))
        }
    }
}
