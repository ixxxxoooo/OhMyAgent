// @author ygw
// ClaudeConfigKit 基础设施:路径解析、JSON 文件的"读-改-写"(保留未知字段)、错误类型。

import Foundation
import OMLog

/// 配置读写错误。
public enum ConfigError: Error, LocalizedError, Equatable {
    case invalidJSON(path: String, reason: String)
    case invalidValue(String)
    case alreadyExists(String)
    case notFound(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let path, let reason): return "无法解析 \(path):\(reason)"
        case .invalidValue(let message): return message
        case .alreadyExists(let name): return "「\(name)」已存在"
        case .notFound(let name): return "找不到「\(name)」"
        case .commandFailed(let message): return message
        }
    }
}

/// 配置作用域。
public enum ConfigScope: String, Sendable, CaseIterable, Hashable, Identifiable {
    case user, project, local
    public var id: String { rawValue }

    /// 界面展示名。
    public var displayName: String {
        switch self {
        case .user: return String(localized: "用户")
        case .project: return String(localized: "scope.project", defaultValue: "项目")
        case .local: return String(localized: "本地")
        }
    }
}

/// Claude Code 各类配置文件的位置。`home` 与 `workspace` 可注入,便于测试。
public struct ClaudePaths: Sendable, Equatable {
    public var home: URL
    public var workspace: URL?

    /// - Parameters:
    ///   - home: 用户主目录
    ///   - workspace: 当前工作区(可为空)
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, workspace: URL? = nil) {
        self.home = home
        self.workspace = workspace
    }

    public var claudeDirectory: URL { home.appendingPathComponent(".claude") }
    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var userSettings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var projectClaudeDirectory: URL? { workspace?.appendingPathComponent(".claude") }
    public var projectSettings: URL? { projectClaudeDirectory?.appendingPathComponent("settings.json") }
    public var projectLocalSettings: URL? { projectClaudeDirectory?.appendingPathComponent("settings.local.json") }
    public var projectMCP: URL? { workspace?.appendingPathComponent(".mcp.json") }
    public var pluginsDirectory: URL { claudeDirectory.appendingPathComponent("plugins") }

    /// 指定作用域的设置文件。
    public func settingsFile(_ scope: ConfigScope) -> URL? {
        switch scope {
        case .user: return userSettings
        case .project: return projectSettings
        case .local: return projectLocalSettings
        }
    }

    /// 指定作用域下某类资源目录(skills / commands / agents / rules)。
    public func directory(_ name: String, scope: ConfigScope) -> URL? {
        switch scope {
        case .user: return claudeDirectory.appendingPathComponent(name)
        case .project, .local: return projectClaudeDirectory?.appendingPathComponent(name)
        }
    }
}

/// JSON 对象文件:读取、原子写入、"读-改-写"。未改动的字段原样保留(键顺序按字母排序)。
public struct JSONFile: Sendable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    /// 读取根对象;文件不存在返回空对象。
    /// - Throws: `ConfigError.invalidJSON` 当内容不是合法 JSON 对象
    public func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigError.invalidJSON(path: url.path, reason: "根节点不是对象")
            }
            return object
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError.invalidJSON(path: url.path, reason: error.localizedDescription)
        }
    }

    /// 原子写入;写入前把旧文件复制为 `<文件名>.oma-backup`。
    /// - Parameter object: 根对象
    public func write(_ object: [String: Any]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(url.lastPathComponent + ".oma-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        Log.config.info("配置已写回", ["file": url.path, "bytes": "\(data.count)", "topKeys": "\(object.count)"])
    }

    /// 读-改-写。
    /// - Parameter body: 对根对象的修改
    public func update(_ body: (inout [String: Any]) throws -> Void) throws {
        var object = try read()
        try body(&object)
        try write(object)
    }
}

/// 嵌套字典的路径读写工具。
enum JSONPath {
    /// 读取路径对应的值。
    static func get(_ object: [String: Any], _ path: [String]) -> Any? {
        var current: Any? = object
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    /// 设置路径对应的值;`value` 为 nil 时删除,并清理变空的父级字典。
    static func set(_ object: inout [String: Any], _ path: [String], _ value: Any?) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if let value { object[first] = value } else { object.removeValue(forKey: first) }
            return
        }
        var child = object[first] as? [String: Any] ?? [:]
        set(&child, Array(path.dropFirst()), value)
        if child.isEmpty && value == nil { object.removeValue(forKey: first) } else { object[first] = child }
    }
}
