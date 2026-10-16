// @author ygw
// 项目信任:读写 `~/.claude.json` 中 `projects[<路径>].hasTrustDialogAccepted`。
// 未信任的项目,Claude Code 不会自动执行其项目级 Hooks / MCP / 环境变量等。

import Foundation

/// 项目信任读写。
public struct ProjectTrust: Sendable {
    public let paths: ClaudePaths

    /// - Parameter paths: 配置路径(测试可注入 home)
    public init(paths: ClaudePaths = ClaudePaths()) {
        self.paths = paths
    }

    /// 读取某项目的信任状态。
    /// - Parameter projectPath: 项目目录(绝对路径)
    /// - Returns: 已信任为 true;未记录或未信任为 false
    public func isTrusted(_ projectPath: String) -> Bool {
        guard !projectPath.isEmpty, let root = try? JSONFile(paths.claudeJSON).read(),
              let projects = root["projects"] as? [String: Any],
              let project = projects[Self.normalize(projectPath)] as? [String: Any] else { return false }
        return project["hasTrustDialogAccepted"] as? Bool ?? false
    }

    /// 批量读取信任状态。
    /// - Parameter projectPaths: 项目目录列表
    /// - Returns: 路径 → 是否信任
    public func statuses(for projectPaths: [String]) -> [String: Bool] {
        guard let root = try? JSONFile(paths.claudeJSON).read(), let projects = root["projects"] as? [String: Any] else {
            return Dictionary(uniqueKeysWithValues: projectPaths.map { ($0, false) })
        }
        var result: [String: Bool] = [:]
        for path in projectPaths {
            let project = projects[Self.normalize(path)] as? [String: Any]
            result[path] = project?["hasTrustDialogAccepted"] as? Bool ?? false
        }
        return result
    }

    /// 设置某项目的信任状态(保留该项目与文件中的其它字段)。
    /// - Parameters:
    ///   - trusted: 是否信任
    ///   - projectPath: 项目目录(绝对路径)
    /// - Throws: `ConfigError.invalidValue`(路径为空)或文件读写错误
    public func setTrusted(_ trusted: Bool, for projectPath: String) throws {
        guard !projectPath.isEmpty else { throw ConfigError.invalidValue("项目路径为空") }
        let key = Self.normalize(projectPath)
        try JSONFile(paths.claudeJSON).update { root in
            var projects = root["projects"] as? [String: Any] ?? [:]
            var project = projects[key] as? [String: Any] ?? [:]
            project["hasTrustDialogAccepted"] = trusted
            projects[key] = project
            root["projects"] = projects
        }
    }

    /// 标准化路径(去掉末尾斜杠,与 Claude Code 的键一致)。
    static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
