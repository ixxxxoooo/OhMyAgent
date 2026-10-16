// @author ixxxxoooo
// Agent 注册表:`~/Library/Application Support/OhMyAgent/agents.json`。
// 保存用户自定义的 ACP Agent、作为 MCP 工具源登记的 Agent(Agent-as-MCP)、默认 Agent 与 Bridge 开关。

import ACPKit
import Foundation

/// 作为 MCP 工具源登记的 Agent(例如 `codex mcp-server`、`claude mcp serve`)。
public struct AgentMCPEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var enabled: Bool

    public init(id: String, name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    private enum Keys: String, CodingKey { case id, name, command, args, env, enabled }

    /// 常用预设。
    public static let presets: [AgentMCPEntry] = [
        AgentMCPEntry(id: "codex", name: "Codex", command: "codex", args: ["mcp-server"], enabled: false),
        AgentMCPEntry(id: "claude-code-mcp", name: String(localized: "Claude Code(MCP 服务)"), command: "claude", args: ["mcp", "serve"], enabled: false),
    ]

    /// 转换为 `session/new` 的 stdio MCP 配置。
    /// - Parameter path: 用于解析命令名的 PATH
    public func serverConfig(path: String) -> MCPServerConfig {
        let resolved = GenericACPProvider.resolve(command, path: path) ?? command
        return .stdio(name: "agent_" + id.replacingOccurrences(of: "-", with: "_"), command: resolved, args: args, env: env)
    }
}

/// Bridge 设置。
public struct BridgeSettings: Codable, Sendable, Equatable {
    public var enabled = true
    /// 被显式关闭的工具名(rawValue);未列出的视为开启
    public var disabledTools: [String] = []

    public init(enabled: Bool = true, disabledTools: [String] = []) {
        self.enabled = enabled
        self.disabledTools = disabledTools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }

    private enum Keys: String, CodingKey { case enabled, disabledTools }

    /// 当前启用的工具集合。
    public var enabledTools: Set<BridgeTool> { Set(BridgeTool.allCases.filter { !disabledTools.contains($0.rawValue) }) }
}

/// 注册表内容。
public struct AgentRegistryData: Codable, Sendable, Equatable {
    public var version = 1
    public var defaultAgent: String?
    public var agents: [AgentDescriptor] = []
    public var mcpAgents: [AgentMCPEntry] = []
    public var bridge = BridgeSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        defaultAgent = try c.decodeIfPresent(String.self, forKey: .defaultAgent)
        agents = try c.decodeIfPresent([AgentDescriptor].self, forKey: .agents) ?? []
        mcpAgents = try c.decodeIfPresent([AgentMCPEntry].self, forKey: .mcpAgents) ?? []
        bridge = try c.decodeIfPresent(BridgeSettings.self, forKey: .bridge) ?? BridgeSettings()
    }

    private enum Keys: String, CodingKey { case version, defaultAgent, agents, mcpAgents, bridge }

    /// 内置 + 自定义的全部 Agent(内置在前;自定义同 id 会覆盖内置的启用状态之外的字段被忽略)。
    public var allAgents: [AgentDescriptor] {
        let builtIn = AgentDescriptor.builtIns
        let custom = agents.filter { item in !builtIn.contains { $0.id == item.id } }
        return builtIn + custom
    }

    /// 已启用的 Agent。
    public var enabledAgents: [AgentDescriptor] { allAgents.filter(\.enabled) }

    /// 默认 Agent:配置的默认且仍启用 > Claude Code。
    public var resolvedDefault: AgentDescriptor {
        enabledAgents.first { $0.id == defaultAgent } ?? .claudeCode
    }

    /// 已启用的 Agent-as-MCP 登记项。
    public var enabledMCPAgents: [AgentMCPEntry] { mcpAgents.filter(\.enabled) }
}

/// 注册表文件读写。
public struct AgentRegistryStore: Sendable {
    public let url: URL

    /// - Parameter url: agents.json 路径;默认在用户的 Application Support 下
    public init(url: URL = AgentRegistryStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OhMyAgent", isDirectory: true).appendingPathComponent("agents.json")
    }

    /// 读取;文件缺失或损坏时返回默认内容(损坏文件不会被覆盖,直到下一次保存)。
    public func load() -> AgentRegistryData {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(AgentRegistryData.self, from: data) else { return AgentRegistryData() }
        return value
    }

    /// 保存(先备份旧文件,再原子写入)。
    public func save(_ value: AgentRegistryData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("oma-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

extension AgentDescriptor {
    /// 内置 Agent:Claude Code(ACP 适配器)。
    public static let builtIns: [AgentDescriptor] = [.claudeCode]

    /// 容错解码:手写的 agents.json 缺省字段时使用默认值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(
            id: id,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? id,
            kind: (try? c.decodeIfPresent(AgentKind.self, forKey: .kind)) ?? .genericACP,
            command: try c.decodeIfPresent(String.self, forKey: .command),
            args: try c.decodeIfPresent([String].self, forKey: .args) ?? [],
            env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            summary: try c.decodeIfPresent(String.self, forKey: .summary),
            registryId: try c.decodeIfPresent(String.self, forKey: .registryId)
        )
    }

    private enum Keys: String, CodingKey { case id, name, kind, command, args, env, enabled, summary, registryId }
}
