// @author ixxxxoooo
// settings.json 分层读写(用户 / 项目 / 本地),按键路径读取与写回,保留未知字段。

import Foundation

/// 设置存储。
public struct SettingsStore: Sendable {
    public var paths: ClaudePaths

    public init(paths: ClaudePaths) { self.paths = paths }

    /// 读取某层设置的根对象;该层不可用(没有工作区)时返回空对象。
    public func read(_ scope: ConfigScope) throws -> [String: Any] {
        guard let url = paths.settingsFile(scope) else { return [:] }
        return try JSONFile(url).read()
    }

    /// 读取某层某个键路径的值。
    /// - Parameters:
    ///   - path: 键路径,如 `["permissions", "defaultMode"]`
    ///   - scope: 设置层
    public func value(_ path: [String], in scope: ConfigScope) -> Any? {
        guard let object = try? read(scope) else { return nil }
        return JSONPath.get(object, path)
    }

    /// 生效值:本地 > 项目 > 用户(标量覆盖;不做数组合并)。
    public func effectiveValue(_ path: [String]) -> (value: Any, scope: ConfigScope)? {
        for scope in [ConfigScope.local, .project, .user] {
            if let value = value(path, in: scope) { return (value, scope) }
        }
        return nil
    }

    /// 写入某层某个键路径;`value` 为 nil 表示删除该键。
    /// - Throws: 没有工作区却写项目/本地层,或文件内容非法
    public func set(_ path: [String], to value: Any?, in scope: ConfigScope) throws {
        guard let url = paths.settingsFile(scope) else {
            throw ConfigError.invalidValue(String(localized: "当前没有工作区,无法写入\(scope.displayName)设置"))
        }
        guard !path.isEmpty else { throw ConfigError.invalidValue(String(localized: "键路径不能为空")) }
        try JSONFile(url).update { JSONPath.set(&$0, path, value) }
    }
}
