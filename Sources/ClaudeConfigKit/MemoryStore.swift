// @author ygw
// 记忆与指令文件:CLAUDE.md / AGENTS.md / CLAUDE.local.md / rules。

import Foundation

/// 一个指令文件。
public struct MemoryFile: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case user, project, projectInClaudeDir, agentsMD, local, userRule, projectRule }
    public var id: String { url.path }
    public var kind: Kind
    public var title: String
    public var url: URL
    public var exists: Bool
    /// 规则文件的 `paths` 限定
    public var pathFilters: [String]
    /// 是否会被 Claude 自动加载(CLAUDE.md 与 rules;AGENTS.md 仅作为兼容展示)
    public var isLoadedByDefault: Bool
}

/// 记忆存储。
public struct MemoryStore: Sendable {
    public var paths: ClaudePaths

    public init(paths: ClaudePaths) { self.paths = paths }

    /// 列出所有指令文件(不存在的标准位置也会列出,方便一键创建)。
    public func list() -> [MemoryFile] {
        var files: [MemoryFile] = []
        func add(_ kind: MemoryFile.Kind, _ title: String, _ url: URL, loaded: Bool = true) {
            files.append(MemoryFile(kind: kind, title: title, url: url, exists: FileManager.default.fileExists(atPath: url.path),
                                    pathFilters: Self.pathFilters(of: url), isLoadedByDefault: loaded))
        }
        add(.user, "用户记忆 ~/.claude/CLAUDE.md", paths.claudeDirectory.appendingPathComponent("CLAUDE.md"))
        if let workspace = paths.workspace {
            add(.project, "项目 CLAUDE.md", workspace.appendingPathComponent("CLAUDE.md"))
            add(.projectInClaudeDir, "项目 .claude/CLAUDE.md", workspace.appendingPathComponent(".claude/CLAUDE.md"))
            add(.local, "本地 CLAUDE.local.md", workspace.appendingPathComponent("CLAUDE.local.md"))
            let agents = workspace.appendingPathComponent("AGENTS.md")
            if FileManager.default.fileExists(atPath: agents.path) { add(.agentsMD, "项目 AGENTS.md", agents, loaded: false) }
        }
        for url in markdownFiles(in: paths.claudeDirectory.appendingPathComponent("rules")) {
            add(.userRule, "用户规则 \(url.lastPathComponent)", url)
        }
        if let rules = paths.projectClaudeDirectory?.appendingPathComponent("rules") {
            for url in markdownFiles(in: rules) { add(.projectRule, "项目规则 \(url.lastPathComponent)", url) }
        }
        return files
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    }

    static func pathFilters(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return MarkdownDocument(parsing: text).list("paths") ?? []
    }

    /// 读取文件内容;不存在返回空串。
    public func read(_ file: MemoryFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    /// 保存(必要时创建目录与文件)。
    public func write(_ text: String, to file: MemoryFile) throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file.url, atomically: true, encoding: .utf8)
    }

    /// 新建规则文件。
    /// - Parameters:
    ///   - name: 文件名(不含扩展名)
    ///   - scope: 用户或项目
    ///   - pathFilters: 可选的 `paths` 限定
    @discardableResult
    public func createRule(name: String, scope: ConfigScope, pathFilters: [String]) throws -> URL {
        guard name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { throw ConfigError.invalidValue("文件名只能包含字母、数字、点、下划线和连字符") }
        guard let directory = paths.directory("rules", scope: scope == .local ? .project : scope) else { throw ConfigError.invalidValue("当前没有工作区") }
        let url = directory.appendingPathComponent("\(name).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ConfigError.alreadyExists(name) }
        var document = MarkdownDocument(body: "\n# \(name)\n\n")
        document.setList("paths", pathFilters)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.render().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 删除规则文件。
    public func deleteRule(_ file: MemoryFile) throws {
        guard file.kind == .userRule || file.kind == .projectRule else { throw ConfigError.invalidValue("只能删除规则文件") }
        SkillStore.trash(file.url)
    }
}
