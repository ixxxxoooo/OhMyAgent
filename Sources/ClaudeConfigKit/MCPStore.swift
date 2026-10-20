// @author ixxxxoooo
// MCP 服务器配置:跨 user / local / project 作用域读写,优先级解析,启停与项目审批,JSON 导入与校验。
// 存储位置:user=~/.claude.json 顶层 mcpServers;local=~/.claude.json 的 projects[<工作区>].mcpServers;
// project=<工作区>/.mcp.json。优先级:local > project > user。

import Foundation

/// MCP 传输类型。
public enum MCPTransportKind: String, Sendable, CaseIterable, Identifiable {
    case stdio, http, sse, ws
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .stdio: return String(localized: "stdio(本地进程)")
        case .http: return "HTTP"
        case .sse: return String(localized: "SSE(已弃用)")
        case .ws: return "WebSocket"
        }
    }
}

/// 一个 MCP 服务器的配置。
public struct MCPServerConfig: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var transport: MCPTransportKind
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var url: String
    public var headers: [String: String]

    public init(name: String, transport: MCPTransportKind = .stdio, command: String = "", args: [String] = [],
                env: [String: String] = [:], url: String = "", headers: [String: String] = [:]) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    /// 从配置字典解析。
    init(name: String, dictionary: [String: Any]) {
        let type = (dictionary["type"] as? String) ?? ((dictionary["url"] != nil && dictionary["command"] == nil) ? "http" : "stdio")
        self.init(
            name: name,
            transport: MCPTransportKind(rawValue: type) ?? .stdio,
            command: dictionary["command"] as? String ?? "",
            args: dictionary["args"] as? [String] ?? [],
            env: dictionary["env"] as? [String: String] ?? [:],
            url: dictionary["url"] as? String ?? "",
            headers: dictionary["headers"] as? [String: String] ?? [:]
        )
    }

    /// 把已知字段写入字典,其余未知字段保持不变。
    func apply(to dictionary: inout [String: Any]) {
        dictionary["type"] = transport.rawValue
        func put(_ key: String, _ value: String) { if value.isEmpty { dictionary.removeValue(forKey: key) } else { dictionary[key] = value } }
        if transport == .stdio {
            put("command", command)
            if args.isEmpty { dictionary.removeValue(forKey: "args") } else { dictionary["args"] = args }
            if env.isEmpty { dictionary.removeValue(forKey: "env") } else { dictionary["env"] = env }
            dictionary.removeValue(forKey: "url")
            dictionary.removeValue(forKey: "headers")
        } else {
            put("url", url)
            if headers.isEmpty { dictionary.removeValue(forKey: "headers") } else { dictionary["headers"] = headers }
            dictionary.removeValue(forKey: "command")
            dictionary.removeValue(forKey: "args")
            if env.isEmpty { dictionary.removeValue(forKey: "env") } else { dictionary["env"] = env }
        }
    }
}

/// 列表中的 MCP 条目(含作用域与状态)。
public struct MCPServerEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(scope.rawValue):\(config.name)" }
    public var config: MCPServerConfig
    public var scope: ConfigScope
    /// 被哪个更高优先级的作用域覆盖(同名)
    public var overriddenBy: ConfigScope?
    public var isDisabled: Bool
    /// 项目级服务器尚未获得用户批准
    public var needsApproval: Bool

    public init(config: MCPServerConfig, scope: ConfigScope, overriddenBy: ConfigScope? = nil, isDisabled: Bool = false, needsApproval: Bool = false) {
        self.config = config
        self.scope = scope
        self.overriddenBy = overriddenBy
        self.isDisabled = isDisabled
        self.needsApproval = needsApproval
    }
}

/// `claude mcp list` 的连接状态。
public struct MCPHealthStatus: Sendable, Equatable {
    public enum State: String, Sendable { case connected, needsAuth, failed, unknown }
    public var name: String
    public var state: State
    public var detail: String

    public init(name: String, state: State, detail: String = "") {
        self.name = name
        self.state = state
        self.detail = detail
    }
}

/// MCP 存储。
public struct MCPStore: Sendable {
    public var paths: ClaudePaths

    public init(paths: ClaudePaths) { self.paths = paths }

    // MARK: - 读取

    /// 读取全部作用域的服务器。
    public func list() throws -> [MCPServerEntry] {
        var entries: [MCPServerEntry] = []
        let claude = try JSONFile(paths.claudeJSON).read()
        let projectKey = paths.workspace?.path
        let projectEntry = projectKey.flatMap { (claude["projects"] as? [String: Any])?[$0] as? [String: Any] }

        for (name, raw) in (claude["mcpServers"] as? [String: Any]) ?? [:] {
            if let dictionary = raw as? [String: Any] { entries.append(makeEntry(name, dictionary, .user, projectEntry: projectEntry)) }
        }
        for (name, raw) in (projectEntry?["mcpServers"] as? [String: Any]) ?? [:] {
            if let dictionary = raw as? [String: Any] { entries.append(makeEntry(name, dictionary, .local, projectEntry: projectEntry)) }
        }
        if let url = paths.projectMCP {
            let file = try JSONFile(url).read()
            for (name, raw) in (file["mcpServers"] as? [String: Any]) ?? [:] {
                if let dictionary = raw as? [String: Any] { entries.append(makeEntry(name, dictionary, .project, projectEntry: projectEntry)) }
            }
        }
        // 覆盖关系:local > project > user
        let rank: [ConfigScope: Int] = [.local: 3, .project: 2, .user: 1]
        for index in entries.indices {
            let winner = entries.filter { $0.config.name == entries[index].config.name }.max { (rank[$0.scope] ?? 0) < (rank[$1.scope] ?? 0) }
            if let winner, winner.scope != entries[index].scope { entries[index].overriddenBy = winner.scope }
        }
        return entries.sorted { ($0.config.name, $0.scope.rawValue) < ($1.config.name, $1.scope.rawValue) }
    }

    private func makeEntry(_ name: String, _ dictionary: [String: Any], _ scope: ConfigScope, projectEntry: [String: Any]?) -> MCPServerEntry {
        let settings = SettingsStore(paths: paths)
        let disabledInProject = (projectEntry?["disabledMcpServers"] as? [String])?.contains(name) ?? false
        var disabledByJSON = false
        var approved = true
        if scope == .project {
            for layer in ConfigScope.allCases {
                if (settings.value(["disabledMcpjsonServers"], in: layer) as? [String])?.contains(name) == true { disabledByJSON = true }
            }
            let enabledAll = ConfigScope.allCases.contains { settings.value(["enableAllProjectMcpServers"], in: $0) as? Bool == true }
            let enabledNamed = ConfigScope.allCases.contains { (settings.value(["enabledMcpjsonServers"], in: $0) as? [String])?.contains(name) == true }
            approved = enabledAll || enabledNamed
        }
        return MCPServerEntry(config: MCPServerConfig(name: name, dictionary: dictionary), scope: scope, overriddenBy: nil,
                              isDisabled: disabledInProject || disabledByJSON, needsApproval: scope == .project && !approved && !disabledByJSON)
    }

    // MARK: - 写入

    /// 新增或更新服务器。
    /// - Parameters:
    ///   - config: 服务器配置(会先校验)
    ///   - scope: 目标作用域
    ///   - replacing: 重命名时的旧名称
    public func save(_ config: MCPServerConfig, scope: ConfigScope, replacing oldName: String? = nil) throws {
        let problems = Self.validate(config)
        if let first = problems.first { throw ConfigError.invalidValue(first) }
        try mutateServers(scope) { servers in
            if let oldName, oldName != config.name { servers.removeValue(forKey: oldName) }
            var dictionary = servers[config.name] as? [String: Any] ?? [:]
            config.apply(to: &dictionary)
            servers[config.name] = dictionary
        }
    }

    /// 删除服务器。
    public func remove(name: String, scope: ConfigScope) throws {
        var existed = false
        try mutateServers(scope) { servers in existed = servers.removeValue(forKey: name) != nil }
        if !existed { throw ConfigError.notFound(name) }
    }

    /// 通过 JSON 文本添加(等价 `claude mcp add-json`)。
    /// - Parameters:
    ///   - name: 服务器名
    ///   - json: 配置 JSON(单个服务器对象)
    ///   - scope: 目标作用域
    public func addJSON(name: String, json: String, scope: ConfigScope) throws {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidValue(String(localized: "JSON 格式不正确,需要是一个对象"))
        }
        let config = MCPServerConfig(name: name, dictionary: object)
        if let first = Self.validate(config).first { throw ConfigError.invalidValue(first) }
        try mutateServers(scope) { servers in
            var dictionary = object
            config.apply(to: &dictionary)
            servers[name] = dictionary
        }
    }

    /// 启用/禁用服务器。项目级服务器写入 `settings.local.json` 的 `disabledMcpjsonServers`/`enabledMcpjsonServers`;
    /// 其它作用域写入 `~/.claude.json` 中该工作区的 `disabledMcpServers`。
    public func setEnabled(_ enabled: Bool, name: String, scope: ConfigScope) throws {
        let settings = SettingsStore(paths: paths)
        if scope == .project {
            var disabled = (settings.value(["disabledMcpjsonServers"], in: .local) as? [String]) ?? []
            var allowed = (settings.value(["enabledMcpjsonServers"], in: .local) as? [String]) ?? []
            if enabled {
                disabled.removeAll { $0 == name }
                if !allowed.contains(name) { allowed.append(name) }
            } else {
                allowed.removeAll { $0 == name }
                if !disabled.contains(name) { disabled.append(name) }
            }
            try settings.set(["disabledMcpjsonServers"], to: disabled.isEmpty ? nil : disabled, in: .local)
            try settings.set(["enabledMcpjsonServers"], to: allowed.isEmpty ? nil : allowed, in: .local)
            return
        }
        guard let key = paths.workspace?.path else { throw ConfigError.invalidValue(String(localized: "当前没有工作区")) }
        try JSONFile(paths.claudeJSON).update { root in
            var projects = root["projects"] as? [String: Any] ?? [:]
            var project = projects[key] as? [String: Any] ?? [:]
            var disabled = project["disabledMcpServers"] as? [String] ?? []
            if enabled { disabled.removeAll { $0 == name } } else if !disabled.contains(name) { disabled.append(name) }
            project["disabledMcpServers"] = disabled
            projects[key] = project
            root["projects"] = projects
        }
    }

    /// 批准项目级(`.mcp.json`)服务器。
    public func approveProjectServer(name: String) throws {
        try setEnabled(true, name: name, scope: .project)
    }

    /// 读取 Claude Desktop 的 MCP 配置,供导入。
    public static func claudeDesktopServers(home: URL) -> [MCPServerConfig] {
        let url = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let object = try? JSONFile(url).read(), let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, raw in (raw as? [String: Any]).map { MCPServerConfig(name: name, dictionary: $0) } }
            .sorted { $0.name < $1.name }
    }

    private func mutateServers(_ scope: ConfigScope, _ body: (inout [String: Any]) -> Void) throws {
        switch scope {
        case .user:
            try JSONFile(paths.claudeJSON).update { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                body(&servers)
                root["mcpServers"] = servers
            }
        case .local:
            guard let key = paths.workspace?.path else { throw ConfigError.invalidValue(String(localized: "当前没有工作区,无法写入本地作用域")) }
            try JSONFile(paths.claudeJSON).update { root in
                var projects = root["projects"] as? [String: Any] ?? [:]
                var project = projects[key] as? [String: Any] ?? [:]
                var servers = project["mcpServers"] as? [String: Any] ?? [:]
                body(&servers)
                project["mcpServers"] = servers
                projects[key] = project
                root["projects"] = projects
            }
        case .project:
            guard let url = paths.projectMCP else { throw ConfigError.invalidValue(String(localized: "当前没有工作区,无法写入项目作用域")) }
            try JSONFile(url).update { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                body(&servers)
                root["mcpServers"] = servers
            }
        }
    }

    // MARK: - 校验

    /// 校验配置,返回问题列表(空表示通过)。
    public static func validate(_ config: MCPServerConfig) -> [String] {
        var problems: [String] = []
        let name = config.name
        if name.isEmpty || name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            problems.append(String(localized: "名称只能包含字母、数字、下划线和连字符"))
        }
        if config.transport == .stdio {
            if config.command.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "stdio 服务器需要填写命令")) }
        } else {
            let scheme = URL(string: config.url)?.scheme?.lowercased()
            let allowed = config.transport == .ws ? ["ws", "wss"] : ["http", "https"]
            if config.url.isEmpty || scheme == nil || !allowed.contains(scheme!) {
                problems.append(String(localized: "URL 无效,\(config.transport.displayName) 需要以 \(allowed.joined(separator: String(localized: " 或 "))) 开头"))
            }
        }
        return problems
    }

    /// 配置中引用但环境里不存在、也没有默认值的 `${VAR}` 变量。
    /// - Parameters:
    ///   - config: 服务器配置
    ///   - environment: 环境变量表
    public static func unresolvedVariables(in config: MCPServerConfig, environment: [String: String]) -> [String] {
        var texts = [config.command, config.url] + config.args + Array(config.env.values) + Array(config.headers.values)
        texts = texts.filter { $0.contains("${") }
        guard let regex = try? NSRegularExpression(pattern: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)(:-[^}]*)?\\}") else { return [] }
        var missing = Set<String>()
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let name = (text as NSString).substring(with: match.range(at: 1))
                let hasDefault = match.range(at: 2).location != NSNotFound
                if !hasDefault, environment[name] == nil { missing.insert(name) }
            }
        }
        return missing.sorted()
    }

    /// 解析 `claude mcp list` 的输出。
    /// - Parameter output: 命令标准输出
    public static func parseHealth(_ output: String) -> [MCPHealthStatus] {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let colon = text.range(of: ": ") else { return nil }
            let name = String(text[..<colon.lowerBound])
            guard !name.contains(" ") || name.hasPrefix("plugin:") || name.hasPrefix("claude.ai") else { return nil }
            let rest = String(text[colon.upperBound...])
            let state: MCPHealthStatus.State
            if rest.contains("✓") || rest.localizedCaseInsensitiveContains("connected") && !rest.localizedCaseInsensitiveContains("not connected") { state = .connected }
            else if rest.localizedCaseInsensitiveContains("needs auth") || rest.contains("!") { state = .needsAuth }
            else if rest.contains("✗") || rest.localizedCaseInsensitiveContains("failed") { state = .failed }
            else { return nil }
            return MCPHealthStatus(name: name, state: state, detail: rest)
        }
    }
}
