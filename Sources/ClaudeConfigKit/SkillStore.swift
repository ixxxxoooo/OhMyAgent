// @author ygw
// Skills / 斜杠命令 与 Subagents 的目录扫描、创建、编辑、删除。
// Skill:`<scope>/.claude/skills/<name>/SKILL.md`;命令:`<scope>/.claude/commands/<name>.md`;
// Subagent:`<scope>/.claude/agents/<name>.md`;插件内的同名目录只读展示。

import Foundation

/// 条目来源。
public enum ItemSource: Sendable, Hashable {
    case scope(ConfigScope)
    case plugin(String)

    public var displayName: String {
        switch self {
        case .scope(let scope): return scope.displayName
        case .plugin(let name): return "插件 \(name)"
        }
    }
    public var isReadOnly: Bool { if case .plugin = self { return true } else { return false } }
}

/// Skill、命令或 Subagent 条目。
public struct MarkdownItem: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case skill, command, agent }
    public var id: String { fileURL.path }
    public var kind: Kind
    /// 调用名(插件内为 `plugin:name`)
    public var name: String
    public var description: String
    public var source: ItemSource
    /// 实际的 Markdown 文件
    public var fileURL: URL
    /// 条目目录(Skill 为其所在目录,可整体删除);命令/Agent 为 nil
    public var directoryURL: URL?
    public var isSymlink: Bool
    public var disableModelInvocation: Bool
    public var userInvocable: Bool
    /// 被更高优先级来源覆盖
    public var overriddenBy: ItemSource?
}

/// Skill 模板。
public enum SkillTemplate: String, Sendable, CaseIterable, Identifiable {
    case manual, automatic, fork
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .manual: return "手动调用"
        case .automatic: return "模型自动调用"
        case .fork: return "子代理(fork)"
        }
    }
}

/// Skill 与命令存储。
public struct SkillStore: Sendable {
    public var paths: ClaudePaths
    /// 已安装插件的安装目录(名称 → 目录),用于只读展示
    public var pluginRoots: [String: URL]

    public init(paths: ClaudePaths, pluginRoots: [String: URL] = [:]) {
        self.paths = paths
        self.pluginRoots = pluginRoots
    }

    static let namePattern = "^[a-z0-9][a-z0-9-]{0,63}$"

    /// 列出全部 Skill 与命令。
    public func list() -> [MarkdownItem] {
        var items: [MarkdownItem] = []
        for scope in [ConfigScope.user, .project] {
            if let skills = paths.directory("skills", scope: scope) { items += scanSkills(skills, source: .scope(scope), prefix: nil) }
            if let commands = paths.directory("commands", scope: scope) { items += scanCommands(commands, source: .scope(scope), prefix: nil) }
        }
        for (plugin, root) in pluginRoots.sorted(by: { $0.key < $1.key }) {
            items += scanSkills(root.appendingPathComponent("skills"), source: .plugin(plugin), prefix: plugin)
            items += scanCommands(root.appendingPathComponent("commands"), source: .plugin(plugin), prefix: plugin)
        }
        // 同名覆盖:个人 > 项目;插件使用命名空间,不参与覆盖
        let rank: [String: Int] = ["用户": 2, "项目": 1]
        for index in items.indices where !items[index].source.isReadOnly {
            let mine = rank[items[index].source.displayName] ?? 0
            if let winner = items.first(where: { !$0.source.isReadOnly && $0.name == items[index].name && (rank[$0.source.displayName] ?? 0) > mine }) {
                items[index].overriddenBy = winner.source
            }
        }
        return items.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    private func scanSkills(_ directory: URL, source: ItemSource, prefix: String?) -> [MarkdownItem] {
        entries(in: directory).compactMap { entry in
            let resolved = entry.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let file = resolved.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return makeItem(file: file, kind: .skill, fallbackName: entry.lastPathComponent, source: source, prefix: prefix,
                            directory: resolved, symlink: resolved.path != entry.standardizedFileURL.path)
        }
    }

    private func scanCommands(_ directory: URL, source: ItemSource, prefix: String?) -> [MarkdownItem] {
        entries(in: directory).compactMap { entry in
            guard entry.pathExtension == "md" else { return nil }
            return makeItem(file: entry, kind: .command, fallbackName: entry.deletingPathExtension().lastPathComponent,
                            source: source, prefix: prefix, directory: nil, symlink: false)
        }
    }

    private func entries(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeItem(file: URL, kind: MarkdownItem.Kind, fallbackName: String, source: ItemSource, prefix: String?,
                          directory: URL?, symlink: Bool) -> MarkdownItem {
        let document = MarkdownDocument(parsing: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        let baseName = document.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let description = document.value("description") ?? document.body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) } ?? ""
        return MarkdownItem(kind: kind, name: prefix.map { "\($0):\(baseName)" } ?? baseName, description: description, source: source,
                            fileURL: file, directoryURL: directory, isSymlink: symlink,
                            disableModelInvocation: document.bool("disable-model-invocation") ?? false,
                            userInvocable: document.bool("user-invocable") ?? true, overriddenBy: nil)
    }

    // MARK: - 创建 / 保存 / 删除

    /// 新建 Skill。
    /// - Parameters:
    ///   - name: 名称(小写字母、数字、连字符)
    ///   - description: 描述
    ///   - template: 模板
    ///   - scope: 用户或项目
    /// - Returns: 新建的 SKILL.md 路径
    @discardableResult
    public func create(name: String, description: String, template: SkillTemplate, scope: ConfigScope) throws -> URL {
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else {
            throw ConfigError.invalidValue("名称只能包含小写字母、数字和连字符,且不超过 64 个字符")
        }
        guard let base = paths.directory("skills", scope: scope == .local ? .project : scope) else {
            throw ConfigError.invalidValue("当前没有工作区,无法创建项目 Skill")
        }
        let directory = base.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ConfigError.alreadyExists(name) }
        var document = MarkdownDocument(body: "\n# \(name)\n\n在这里写下 Claude 使用这个 Skill 时应遵循的步骤。\n")
        document.setValue("name", name)
        document.setValue("description", description.isEmpty ? "描述这个 Skill 做什么、何时使用" : description)
        switch template {
        case .manual: document.setBool("disable-model-invocation", true)
        case .automatic: break
        case .fork:
            document.setValue("context", "fork")
            document.setValue("agent", "Explore")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("SKILL.md")
        try document.render().write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// 读取条目文档。
    public func load(_ item: MarkdownItem) throws -> MarkdownDocument {
        MarkdownDocument(parsing: try String(contentsOf: item.fileURL, encoding: .utf8))
    }

    /// 保存条目文档(插件内条目只读)。
    public func save(_ document: MarkdownDocument, to item: MarkdownItem) throws {
        guard !item.source.isReadOnly else { throw ConfigError.invalidValue("插件内的条目是只读的") }
        try document.render().write(to: item.fileURL, atomically: true, encoding: .utf8)
    }

    /// 删除条目(移入废纸篓;不可用时直接删除)。
    public func delete(_ item: MarkdownItem) throws {
        guard !item.source.isReadOnly else { throw ConfigError.invalidValue("插件内的条目请通过插件管理卸载") }
        Self.trash(item.directoryURL ?? item.fileURL)
    }

    static func trash(_ url: URL) {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { try? FileManager.default.removeItem(at: url) }
    }
}

/// Subagent 存储。
public struct AgentStore: Sendable {
    public var paths: ClaudePaths
    public var pluginRoots: [String: URL]

    public init(paths: ClaudePaths, pluginRoots: [String: URL] = [:]) {
        self.paths = paths
        self.pluginRoots = pluginRoots
    }

    /// 列出全部 Subagent。
    public func list() -> [MarkdownItem] {
        var items: [MarkdownItem] = []
        func scan(_ directory: URL?, source: ItemSource, prefix: String?) {
            guard let directory else { return }
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let document = MarkdownDocument(parsing: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
                let base = document.value("name").flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
                items.append(MarkdownItem(kind: .agent, name: prefix.map { "\($0):\(base)" } ?? base, description: document.value("description") ?? "",
                                          source: source, fileURL: file, directoryURL: nil, isSymlink: false,
                                          disableModelInvocation: false, userInvocable: true, overriddenBy: nil))
            }
        }
        scan(paths.directory("agents", scope: .user), source: .scope(.user), prefix: nil)
        scan(paths.directory("agents", scope: .project), source: .scope(.project), prefix: nil)
        for (plugin, root) in pluginRoots.sorted(by: { $0.key < $1.key }) { scan(root.appendingPathComponent("agents"), source: .plugin(plugin), prefix: plugin) }
        // 项目 Subagent 优先于用户级(与官方一致:项目 > 用户)
        for index in items.indices where items[index].source == .scope(.user) {
            if let winner = items.first(where: { $0.source == .scope(.project) && $0.name == items[index].name }) { items[index].overriddenBy = winner.source }
        }
        return items.sorted { $0.name < $1.name }
    }

    /// 新建 Subagent。
    /// - Parameters:
    ///   - name: 名称
    ///   - description: 何时委派给它
    ///   - tools: 允许的工具(空表示继承全部)
    ///   - model: 模型别名(可空)
    ///   - prompt: 系统提示
    ///   - scope: 用户或项目
    @discardableResult
    public func create(name: String, description: String, tools: [String], model: String?, prompt: String, scope: ConfigScope) throws -> URL {
        guard name.range(of: SkillStore.namePattern, options: .regularExpression) != nil else {
            throw ConfigError.invalidValue("名称只能包含小写字母、数字和连字符,且不超过 64 个字符")
        }
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError.invalidValue("请填写描述,Claude 依据它决定何时委派") }
        guard let directory = paths.directory("agents", scope: scope == .local ? .project : scope) else {
            throw ConfigError.invalidValue("当前没有工作区,无法创建项目 Subagent")
        }
        let file = directory.appendingPathComponent("\(name).md")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw ConfigError.alreadyExists(name) }
        var document = MarkdownDocument(body: "\n\(prompt.isEmpty ? "你是一个专注的助手。" : prompt)\n")
        document.setValue("name", name)
        document.setValue("description", description)
        document.setList("tools", tools)
        document.setValue("model", model?.isEmpty == true ? nil : model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.render().write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// 保存。
    public func save(_ document: MarkdownDocument, to item: MarkdownItem) throws {
        guard !item.source.isReadOnly else { throw ConfigError.invalidValue("插件内的 Subagent 是只读的") }
        try document.render().write(to: item.fileURL, atomically: true, encoding: .utf8)
    }

    /// 删除。
    public func delete(_ item: MarkdownItem) throws {
        guard !item.source.isReadOnly else { throw ConfigError.invalidValue("插件内的 Subagent 请通过插件管理卸载") }
        SkillStore.trash(item.fileURL)
    }
}
