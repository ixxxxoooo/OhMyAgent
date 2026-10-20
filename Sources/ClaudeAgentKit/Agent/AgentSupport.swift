// @author ixxxxoooo
// 适配器公共支撑类型:进程启动器、适配器配置、客户端通道与客户端能力解析。

import ACPKit
import Foundation

/// `claude` 子进程的传输工厂(生产用标准输入输出,测试用内存传输)。
public protocol ClaudeProcessLauncher: Sendable {
    /// 为一次会话创建与 `claude` 相连的传输。
    /// - Parameter options: 启动选项
    /// - Returns: 尚未启动的传输
    func makeTransport(for options: ClaudeCLIOptions) -> any ACPTransport
}

/// 真实子进程启动器。
public struct StdioProcessLauncher: ClaudeProcessLauncher {
    public init() {}

    public func makeTransport(for options: ClaudeCLIOptions) -> any ACPTransport {
        StdioTransport(launch: ProcessLaunch(
            executable: options.executable,
            arguments: options.arguments(),
            environment: options.launchEnvironment(),
            workingDirectory: options.cwd
        ))
    }
}

/// 适配器配置。
public struct ClaudeAgentConfig: Sendable {
    /// `claude` 可执行文件绝对路径
    public var executable: String
    /// 叠加到 `claude` 子进程的环境变量(如提供商网关的 `ANTHROPIC_*`)
    public var environment: [String: String]
    /// 转录存储
    public var store: TranscriptStore
    /// 设置读取器
    public var settings: SettingsStore
    /// 进程启动器
    public var launcher: any ClaudeProcessLauncher
    /// 适配器版本号(`agentInfo.version`)
    public var version: String
    /// 取消回合后等待 `claude` 回结果的最长时间(秒),超时强制收尾
    public var cancelGraceSeconds: Double

    /// 创建配置。
    /// - Parameters:
    ///   - executable: `claude` 路径
    ///   - environment: 额外环境变量
    ///   - configDirectory: Claude 配置目录;nil 时读环境变量或 `~/.claude`
    ///   - launcher: 进程启动器
    ///   - version: 适配器版本号
    public init(
        executable: String,
        environment: [String: String] = [:],
        configDirectory: URL? = nil,
        launcher: any ClaudeProcessLauncher = StdioProcessLauncher(),
        version: String = "1.0.0",
        managedSettingsPath: String? = nil,
        cancelGraceSeconds: Double = 8
    ) {
        let store = TranscriptStore(configDirectory: configDirectory)
        self.executable = executable
        self.environment = environment
        self.store = store
        if let managedSettingsPath {
            self.settings = SettingsStore(configDirectory: store.configDirectory, managedPath: managedSettingsPath)
        } else {
            self.settings = SettingsStore(configDirectory: store.configDirectory)
        }
        self.launcher = launcher
        self.version = version
        self.cancelGraceSeconds = cancelGraceSeconds
    }
}

/// Agent 到客户端方向的通道(通知与反向请求)。
public protocol AgentClientLink: Sendable {
    /// 发送 `session/update` 通知。
    func sessionUpdate(_ sessionId: String, _ update: JSONValue) async
    /// 向客户端发起请求(`session/request_permission`、`elicitation/create` 等)。
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue
    /// 向客户端发送通知。
    func notify(_ method: String, _ params: JSONValue) async
}

/// 基于 `ACPConnection` 的通道。
public struct ConnectionClientLink: AgentClientLink {
    private let connection: ACPConnection

    public init(connection: ACPConnection) { self.connection = connection }

    public func sessionUpdate(_ sessionId: String, _ update: JSONValue) async {
        await connection.notify("session/update", params: ["sessionId": .string(sessionId), "update": update])
    }

    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await connection.request(method, params: params)
    }

    public func notify(_ method: String, _ params: JSONValue) async {
        await connection.notify(method, params: params)
    }
}

/// 解析后的客户端能力。
struct ClientCaps: Sendable, Equatable {
    var raw: JSONValue = .object([:])
    var terminalOutput: Bool { raw.at("_meta", "terminal_output")?.boolValue == true }
    var elicitationForm: Bool { raw.at("elicitation", "form") != nil }
    var elicitationURL: Bool { raw.at("elicitation", "url") != nil }
    var notices: Bool { Notices.clientSupports(raw) }
    var plan: Bool { raw.at("session", "plan") != nil || raw.at("plan") != nil || raw.at("_meta", "plan")?.boolValue == true }
    var booleanConfig: Bool { raw.at("session", "configOptions", "boolean") != nil }
    var subagentTranscript: Bool { raw.at("_meta", "subagentTranscript")?.boolValue == true }
    var gatewayAuth: Bool { raw.at("auth", "_meta", "gateway")?.boolValue == true }
    var terminalAuth: Bool { raw.at("auth", "terminal")?.boolValue == true }
}

/// 一次 `session/new|load|resume|fork` 的会话参数。
struct SessionSpec: Sendable {
    var cwd: String
    var mcpServers: [JSONValue]
    var additionalDirectories: [String]
    var meta: JSONValue?

    /// 参数指纹:同一会话以相同参数再次加载时复用已有进程。
    var fingerprint: String {
        JSONValue.object([
            "cwd": .string(cwd), "mcp": .array(mcpServers), "dirs": .array(additionalDirectories.map(JSONValue.string)), "meta": meta ?? .null,
        ]).jsonText
    }

    /// 从请求参数解析。
    init(params: JSONValue?) {
        cwd = params?["cwd"]?.stringValue ?? ""
        mcpServers = params?["mcpServers"]?.arrayValue ?? []
        additionalDirectories = (params?["additionalDirectories"]?.arrayValue ?? params?["_meta"]?["additionalRoots"]?.arrayValue ?? []).compactMap(\.stringValue)
        meta = params?["_meta"]
    }
}
