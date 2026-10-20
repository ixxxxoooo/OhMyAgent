// @author ixxxxoooo
// `claude` 命令行启动选项:把会话参数拼成与官方 Agent SDK 一致的参数列表与环境变量。

import ACPKit
import Foundation

/// `claude` 子进程的启动选项(对应 Agent SDK 的 `query()` options)。
public struct ClaudeCLIOptions: Sendable, Equatable {
    /// `claude` 可执行文件绝对路径
    public var executable: String
    /// 工作目录
    public var cwd: String
    /// 额外环境变量(叠加在当前进程环境之上)
    public var env: [String: String] = [:]
    /// 初始模型(`--model`)
    public var model: String?
    /// 思考强度(`--effort`)
    public var effort: String?
    /// 初始权限模式(`--permission-mode`)
    public var permissionMode: String?
    /// 恢复的会话 ID(`--resume`)
    public var resume: String?
    /// 恢复时创建新会话(`--fork-session`)
    public var forkSession = false
    /// 恢复到指定消息(`--resume-session-at`)
    public var resumeSessionAt: String?
    /// 指定会话 ID(`--session-id`)
    public var sessionId: String?
    /// 主线程 Agent 人格(`--agent`)
    public var agent: String?
    /// 备用模型(`--fallback-model`)
    public var fallbackModel: String?
    /// 最大回合数(`--max-turns`)
    public var maxTurns: Int?
    /// 最大预算美元(`--max-budget-usd`)
    public var maxBudgetUSD: Double?
    /// 预先允许的工具(`--allowedTools`)
    public var allowedTools: [String] = []
    /// 禁用的工具(`--disallowedTools`)
    public var disallowedTools: [String] = []
    /// 工具集:nil = 不传;`.preset` = `--tools=default`;`.list` = `--tools a,b`
    public var tools: Tools?
    /// MCP 服务器配置(`--mcp-config`,键为服务器名)
    public var mcpServers: [String: JSONValue] = [:]
    /// 仅使用 `--mcp-config` 中的 MCP(`--strict-mcp-config`)
    public var strictMCPConfig = false
    /// 设置来源(`--setting-sources`),nil 不传
    public var settingSources: [String]?
    /// 内联设置(`--settings`,对象会序列化为 JSON 文本)
    public var settings: JSONValue?
    /// 额外可访问目录(`--add-dir`)
    public var additionalDirectories: [String] = []
    /// 允许把「绕过权限」作为可选模式(`--allow-dangerously-skip-permissions`)
    public var allowDangerouslySkipPermissions = false
    /// 是否输出部分消息(流式增量)
    public var includePartialMessages = true
    /// 是否回放用户消息(`--replay-user-messages`),用于转向与排队确认
    public var replayUserMessages = true
    /// 透传的额外参数:键为不带 `--` 的名字,值为 nil 表示无值开关
    public var extraArgs: [String: String?] = [:]

    /// 工具集选项。
    public enum Tools: Sendable, Equatable {
        /// 默认预设(`--tools=default`)
        case preset
        /// 显式列表(空数组表示禁用全部内置工具)
        case list([String])
    }

    /// 创建启动选项。
    /// - Parameters:
    ///   - executable: `claude` 路径
    ///   - cwd: 工作目录
    public init(executable: String, cwd: String) {
        self.executable = executable
        self.cwd = cwd
    }

    /// 生成命令行参数(顺序与官方 SDK 保持一致,便于对照排查)。
    /// - Returns: 参数数组(不含可执行文件)
    public func arguments() -> [String] {
        var args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
        if let maxTurns { args += ["--max-turns", String(maxTurns)] }
        if let maxBudgetUSD { args += ["--max-budget-usd", String(maxBudgetUSD)] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let agent, !agent.isEmpty { args += ["--agent", agent] }
        args.append("--permission-prompt-tool=stdio")
        if let resume, !resume.isEmpty { args += ["--resume", resume] }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        if !disallowedTools.isEmpty { args += ["--disallowedTools", disallowedTools.joined(separator: ",")] }
        switch tools {
        case .preset: args.append("--tools=default")
        case .list(let list): args += ["--tools", list.joined(separator: ",")]
        case nil: break
        }
        if !mcpServers.isEmpty {
            args += ["--mcp-config", JSONValue.object(["mcpServers": .object(mcpServers)]).jsonText]
        }
        if let settingSources { args += ["--setting-sources", settingSources.joined(separator: ",")] }
        if strictMCPConfig { args.append("--strict-mcp-config") }
        if let permissionMode, !permissionMode.isEmpty { args += ["--permission-mode", permissionMode] }
        if allowDangerouslySkipPermissions { args.append("--allow-dangerously-skip-permissions") }
        if let fallbackModel, !fallbackModel.isEmpty, fallbackModel != model { args += ["--fallback-model", fallbackModel] }
        if includePartialMessages { args.append("--include-partial-messages") }
        for dir in additionalDirectories where !dir.isEmpty { args += ["--add-dir", dir] }
        if forkSession { args.append("--fork-session") }
        if let resumeSessionAt, !resumeSessionAt.isEmpty { args += ["--resume-session-at", resumeSessionAt] }
        if let sessionId, !sessionId.isEmpty { args += ["--session-id", sessionId] }

        var extras = extraArgs
        if replayUserMessages { extras["replay-user-messages"] = .some(nil) }
        if let settings {
            switch settings {
            case .string(let path): extras["settings"] = .some(path)
            case .object, .array: extras["settings"] = .some(settings.jsonText)
            default: break
            }
        }
        for key in extras.keys.sorted() {
            guard let entry = extras[key] else { continue }
            if let value = entry, !value.isEmpty {
                args += ["--\(key)", value]
            } else {
                args.append("--\(key)")
            }
        }
        return args
    }

    /// 启动环境:注入 SDK 入口标识与会话状态事件开关。
    /// - Returns: 需要叠加到进程环境上的变量
    public func launchEnvironment() -> [String: String] {
        var result = env
        if result["CLAUDE_CODE_ENTRYPOINT"] == nil { result["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts" }
        if result["CLAUDE_AGENT_SDK_VERSION"] == nil { result["CLAUDE_AGENT_SDK_VERSION"] = "0.3.300" }
        if result["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == nil { result["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1" }
        result["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
        return result
    }
}
