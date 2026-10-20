// @author ixxxxoooo
// Agent 描述符与提供者协议:新增 ACP Agent 只需增加描述符,无需改代码。

import ACPKit
import ClaudeAgentKit
import Foundation

/// Agent 种类。
public enum AgentKind: String, Codable, Sendable, Hashable {
    /// 通过进程内原生适配器(ClaudeAgentKit)接入 Claude Code
    case claudeACP
    /// 任意 ACP 原生 Agent(Codex CLI、Gemini CLI、Goose、OpenCode 等)
    case genericACP
}

/// Agent 描述符,与 ACP Registry 条目字段对齐(id/name/command/args/env)。
public struct AgentDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: AgentKind
    /// 可执行文件(genericACP 必填;claudeACP 留空由定位器决定)
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var enabled: Bool
    /// 说明文字
    public var summary: String?
    /// ACP Registry 里的标识(非 nil 表示由应用「一键安装」管理,启动时从安装目录解析可执行文件)
    public var registryId: String?

    public init(id: String, name: String, kind: AgentKind, command: String? = nil, args: [String] = [], env: [String: String] = [:], enabled: Bool = true, summary: String? = nil, registryId: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.summary = summary
        self.registryId = registryId
    }

    /// Google Antigravity(官方 `agy_acp_server`):一键安装后使用,可执行文件由安装器管理。
    public static let antigravity = AgentDescriptor(
        id: "antigravity", name: "Google Antigravity", kind: .genericACP, command: nil, args: [], env: [:], enabled: true,
        summary: String(localized: "Google 官方 ACP Server(agy_acp_server),需先在设置里一键安装并登录"), registryId: "antigravity-acp"
    )

    /// 模型环境变量名:Antigravity 启动时的默认模型。
    public static let antigravityModelEnv = "AGY_ACP_DEFAULT_MODEL"

    /// 内置的 Claude Code 描述符。
    public static let claudeCode = AgentDescriptor(
        id: "claude-code",
        name: "Claude Code",
        kind: .claudeACP,
        summary: String(localized: "通过内置原生适配器接入官方 Claude Code")
    )
}

/// 启动前提不满足时的错误。
public enum AgentLaunchError: Error, LocalizedError, Sendable {
    case missingClaude
    case missingCommand(String)
    case missingHelper(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .missingClaude: return String(localized: "未找到 claude 命令行工具。请先安装 Claude Code。")
        case .missingCommand(let name): return String(localized: "Agent「\(name)」未配置可执行文件。")
        case .notInstalled(let name): return String(localized: "Agent「\(name)」尚未安装。请到设置 → Agent 注册表点击「一键安装」。")
        case .missingHelper(let name): return String(localized: "缺少随应用分发的辅助程序 \(name),请重新安装或运行 Scripts/bundle.sh。")
        }
    }
}

/// Agent 接入点:子进程(stdio)或进程内原生适配器。
public enum AgentEndpoint: Sendable {
    /// 作为子进程启动,经 stdio 说 ACP
    case process(ProcessLaunch)
    /// 进程内原生 Claude 适配器:与客户端经内存传输相连,按会话拉起 `claude`
    case inProcess(ClaudeAgentConfig)
}

/// Agent 提供者:负责把描述符变成可连接的接入点。
public protocol AgentProvider: Sendable {
    var descriptor: AgentDescriptor { get }
    /// 生成接入点。
    /// - Parameters:
    ///   - cwd: 工作目录
    ///   - tools: 工具定位结果
    func makeEndpoint(cwd: String, tools: LocatedTools) throws -> AgentEndpoint
}

/// 基于描述符创建提供者。
public enum AgentProviders {
    /// - Parameter descriptor: 描述符
    /// - Returns: 对应的提供者
    public static func make(_ descriptor: AgentDescriptor) -> any AgentProvider {
        switch descriptor.kind {
        case .claudeACP: return ClaudeACPProvider(descriptor: descriptor)
        case .genericACP: return GenericACPProvider(descriptor: descriptor)
        }
    }
}

/// Claude Code(经进程内原生适配器 `ClaudeAcpAgent`)。
public struct ClaudeACPProvider: AgentProvider {
    public var descriptor: AgentDescriptor

    public init(descriptor: AgentDescriptor = .claudeCode) {
        self.descriptor = descriptor
    }

    public func makeEndpoint(cwd: String, tools: LocatedTools) throws -> AgentEndpoint {
        guard let claude = tools.claudePath else { throw AgentLaunchError.missingClaude }
        var env = tools.environment
        // 使用用户已安装并已登录的 claude,凭据由官方进程自行管理
        env["CLAUDE_CODE_EXECUTABLE"] = claude
        for (key, value) in descriptor.env { env[key] = value }
        env[AgentEnvironment.marker] = "1"
        return .inProcess(ClaudeAgentConfig(executable: claude, environment: env, version: Self.adapterVersion))
    }

    /// 原生适配器版本号(`initialize.agentInfo.version`)。
    public static let adapterVersion = "1.0.0"
}

/// 任意 ACP 原生 Agent。
public struct GenericACPProvider: AgentProvider {
    public var descriptor: AgentDescriptor

    public init(descriptor: AgentDescriptor) {
        self.descriptor = descriptor
    }

    public func makeEndpoint(cwd: String, tools: LocatedTools) throws -> AgentEndpoint {
        .process(try makeLaunch(cwd: cwd, tools: tools))
    }

    /// 生成子进程启动配置。
    public func makeLaunch(cwd: String, tools: LocatedTools) throws -> ProcessLaunch {
        var env = tools.environment
        for (key, value) in descriptor.env { env[key] = value }
        env[AgentEnvironment.marker] = "1"
        // 一键安装的 Agent:可执行文件取自安装目录(升级后路径自动跟随)
        if let registryId = descriptor.registryId {
            guard let installed = AgentInstaller().installed(id: registryId) else { throw AgentLaunchError.notInstalled(descriptor.name) }
            return ProcessLaunch(executable: installed.executable, arguments: installed.args + descriptor.args, environment: env, workingDirectory: cwd)
        }
        guard let command = descriptor.command, !command.isEmpty else {
            throw AgentLaunchError.missingCommand(descriptor.name)
        }
        // 允许写命令名(如 `codex`),在 PATH 中解析
        let resolved = Self.resolve(command, path: env["PATH"] ?? "")
        Self.applyOpenCodeOverrides(&env, executable: resolved ?? command, arguments: descriptor.args)
        return ProcessLaunch(executable: resolved ?? command, arguments: descriptor.args, environment: env, workingDirectory: cwd)
    }

    /// OpenCode 的 ACP 模式不会把 `question` 工具的提问转给客户端(直接返回「用户已忽略」),
    /// 禁用它,让模型改用 Bridge 的 `ask_user_question`;用户已自行设置 `OPENCODE_CONFIG_CONTENT` 时不覆盖。
    /// - Parameters:
    ///   - env: 启动环境(就地修改)
    ///   - executable: 可执行文件路径或命令名
    ///   - arguments: 启动参数
    static func applyOpenCodeOverrides(_ env: inout [String: String], executable: String, arguments: [String]) {
        guard isOpenCode(executable), arguments.contains("acp"),
              env["OPENCODE_CONFIG_CONTENT"] == nil else { return }
        env["OPENCODE_CONFIG_CONTENT"] = #"{"permission":{"question":"deny"}}"#
    }

    /// 可执行文件是否是 OpenCode(`opencode`、本机改名的 `opencode2` 等带数字后缀的变体)。
    static func isOpenCode(_ executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent
        guard name.hasPrefix("opencode") else { return false }
        return name.dropFirst("opencode".count).allSatisfy(\.isNumber)
    }

    /// 登录 shell 的 PATH 之外常见的安装目录(GUI 应用拿到的 PATH 往往不含它们)。
    public static func fallbackDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// 在 PATH 中解析可执行文件;找不到时再查常见安装目录。
    /// `opencode` 找不到时会尝试本机常见的改名 `opencode2`。
    /// - Parameters:
    ///   - command: 命令名或绝对路径
    ///   - path: PATH(冒号分隔)
    ///   - fallbacks: PATH 之外的兜底目录(测试可注入)
    /// - Returns: 可执行文件的绝对路径;找不到为 nil
    public static func resolve(_ command: String, path: String, fallbacks: [String] = fallbackDirectories()) -> String? {
        if command.hasPrefix("/") { return command }
        let names = command == "opencode" ? ["opencode", "opencode2"] : [command]
        let directories = path.split(separator: ":").map(String.init) + fallbacks
        for name in names {
            for dir in directories {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
