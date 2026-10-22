// @author ixxxxoooo
// 代码智能的「忽略文件」规则:用户在设置里写的 glob,作用于 ⌘K 文件搜索、@ 补全与全局搜索的索引。

import Foundation

/// 用户自定义的索引忽略规则(每行一个 glob,`#` 开头为注释)。
public struct IndexIgnore: Sendable, Equatable {
    /// 偏好键:多行文本。
    public static let preferenceKey = "codeIntel.ignoreGlobs"

    /// 一条解析后的规则。
    struct Rule: Sendable, Equatable {
        /// 去掉首尾 `/` 后的 glob
        let glob: String
        /// 以 `/` 结尾:只匹配目录
        let directoryOnly: Bool
        /// 含 `/`:匹配相对路径;否则匹配任一路径分量
        let anchored: Bool
    }

    let rules: [Rule]

    /// 空规则。
    public static let none = IndexIgnore(rules: [])

    init(rules: [Rule]) { self.rules = rules }

    /// 从多行文本解析。
    /// - Parameter text: 每行一个 glob;空行与 `#` 注释被忽略
    public init(text: String) {
        rules = text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let dirOnly = trimmed.hasSuffix("/")
            var glob = trimmed
            while glob.hasPrefix("/") { glob.removeFirst() }
            while glob.hasSuffix("/") { glob.removeLast() }
            guard !glob.isEmpty else { return nil }
            return Rule(glob: glob, directoryOnly: dirOnly, anchored: glob.contains("/"))
        }
    }

    /// 读取当前偏好。
    public static func current(_ defaults: UserDefaults = .standard) -> IndexIgnore {
        IndexIgnore(text: defaults.string(forKey: preferenceKey) ?? "")
    }

    /// 偏好键:索引是否读取工作区根目录的 `.gitignore`(默认开启)。
    public static let gitignorePreferenceKey = "codeIntel.useGitignore"

    /// 读取工作区根目录的 `.gitignore`(只读根目录那一份,最大 256KB)。
    /// 取消忽略的 `!` 规则不支持,会被跳过(被它豁免的路径仍按忽略处理)。
    /// - Parameter root: 工作区根目录
    /// - Returns: 解析出的规则;没有文件或读取失败为空规则
    public static func gitignore(root: String) -> IndexIgnore {
        guard !root.isEmpty, let handle = FileHandle(forReadingAtPath: root + "/.gitignore") else { return .none }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), let text = String(data: data, encoding: .utf8) else { return .none }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("!") }
        return IndexIgnore(text: lines.joined(separator: "\n"))
    }

    /// 合并两份规则。
    /// - Parameter other: 另一份规则
    public func merged(with other: IndexIgnore) -> IndexIgnore { IndexIgnore(rules: rules + other.rules) }

    /// 某工作区的有效规则:用户规则,加上(偏好开启时)该工作区的 `.gitignore`。
    /// - Parameters:
    ///   - root: 工作区根目录
    ///   - defaults: 偏好存储
    public static func current(root: String, _ defaults: UserDefaults = .standard) -> IndexIgnore {
        let user = current(defaults)
        guard defaults.object(forKey: gitignorePreferenceKey) as? Bool ?? true else { return user }
        return user.merged(with: gitignore(root: root))
    }

    /// 是否没有任何规则。
    public var isEmpty: Bool { rules.isEmpty }

    /// 判断相对路径是否应被忽略。
    /// - Parameters:
    ///   - relativePath: 相对工作区根的路径(`/` 分隔)
    ///   - isDirectory: 是否目录
    /// - Returns: 命中任一规则返回 true
    public func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        guard !rules.isEmpty, !relativePath.isEmpty else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        for rule in rules {
            if rule.anchored {
                if Self.fnmatch(rule.glob, relativePath) || Self.fnmatch(rule.glob + "/*", relativePath) {
                    if !rule.directoryOnly || isDirectory || components.count > rule.glob.split(separator: "/").count { return true }
                }
            } else {
                // 非目录规则可命中文件名;目录规则只命中目录分量(最后一个分量需 isDirectory)
                for (index, part) in components.enumerated() where Self.fnmatch(rule.glob, part) {
                    let isLast = index == components.count - 1
                    if rule.directoryOnly && isLast && !isDirectory { continue }
                    return true
                }
            }
        }
        return false
    }

    /// 单个 glob 匹配(`*` 可跨 `/`,`?` 单字符,支持 `[...]`)。
    private static func fnmatch(_ pattern: String, _ string: String) -> Bool {
        Darwin.fnmatch(pattern, string, 0) == 0
    }
}
