// @author ixxxxoooo
// Agent 描述符与提供者协议:新增 ACP Agent 只需增加描述符,无需改代码。

import ACPKit
import Foundation

/// Agent 种类。
public enum AgentKind: String, Codable, Sendable, Hashable {
    /// 通过 claude-agent-acp 适配器接入 Claude Code
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

    public init(id: String, name: String, kind: AgentKind, command: String? = nil, args: [String] = [], env: [String: String] = [:], enabled: Bool = true, summary: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.summary = summary
    }

    /// 内置的 Claude Code 描述符。
    public static let claudeCode = AgentDescriptor(
        id: "claude-code",
        name: "Claude Code",
        kind: .claudeACP,
        summary: String(localized: "通过 claude-agent-acp 适配器接入官方 Claude Code")
    )
}

/// 启动前提不满足时的错误。
public enum AgentLaunchError: Error, LocalizedError, Sendable {
    case missingNode
    case missingAdapter
    case missingClaude
    case missingCommand(String)
    case missingHelper(String)

    public var errorDescription: String? {
        switch self {
        case .missingNode: return String(localized: "未找到 Node.js(需要 22 或更高版本)。请安装 Node,或在设置 → 高级中指定路径。")
        case .missingAdapter: return String(localized: "未找到 claude-agent-acp 适配器。应用会自动安装;如仍失败,请检查网络后重试,或在设置 → 高级中指定路径。")
        case .missingClaude: return String(localized: "未找到 claude 命令行工具。请先安装 Claude Code。")
        case .missingCommand(let name): return String(localized: "Agent「\(name)」未配置可执行文件。")
        case .missingHelper(let name): return String(localized: "缺少随应用分发的辅助程序 \(name),请重新安装或运行 Scripts/bundle.sh。")
        }
    }
}

/// Agent 提供者:负责把描述符变成可启动的进程配置。
public protocol AgentProvider: Sendable {
    var descriptor: AgentDescriptor { get }
    /// 生成子进程启动配置。
    /// - Parameters:
    ///   - cwd: 工作目录
    ///   - tools: 工具定位结果
    func makeLaunch(cwd: String, tools: LocatedTools) throws -> ProcessLaunch
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

/// Claude Code(经 claude-agent-acp)。
public struct ClaudeACPProvider: AgentProvider {
    public var descriptor: AgentDescriptor

    public init(descriptor: AgentDescriptor = .claudeCode) {
        self.descriptor = descriptor
    }

    public func makeLaunch(cwd: String, tools: LocatedTools) throws -> ProcessLaunch {
        guard let node = tools.nodePath else { throw AgentLaunchError.missingNode }
        guard let adapter = tools.adapterEntry else { throw AgentLaunchError.missingAdapter }
        guard let claude = tools.claudePath else { throw AgentLaunchError.missingClaude }
        var env = tools.environment
        // 使用用户已安装并已登录的 claude,凭据由官方进程自行管理
        env["CLAUDE_CODE_EXECUTABLE"] = claude
        for (key, value) in descriptor.env { env[key] = value }
        return ProcessLaunch(executable: node, arguments: [adapter] + descriptor.args, environment: env, workingDirectory: cwd)
    }
}

/// 任意 ACP 原生 Agent。
public struct GenericACPProvider: AgentProvider {
    public var descriptor: AgentDescriptor

    public init(descriptor: AgentDescriptor) {
        self.descriptor = descriptor
    }

    public func makeLaunch(cwd: String, tools: LocatedTools) throws -> ProcessLaunch {
        guard let command = descriptor.command, !command.isEmpty else {
            throw AgentLaunchError.missingCommand(descriptor.name)
        }
        var env = tools.environment
        for (key, value) in descriptor.env { env[key] = value }
        // 允许写命令名(如 `codex`),在 PATH 中解析
        let resolved = Self.resolve(command, path: env["PATH"] ?? "")
        return ProcessLaunch(executable: resolved ?? command, arguments: descriptor.args, environment: env, workingDirectory: cwd)
    }

    /// 在 PATH 中解析可执行文件。
    public static func resolve(_ command: String, path: String) -> String? {
        if command.hasPrefix("/") { return command }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
