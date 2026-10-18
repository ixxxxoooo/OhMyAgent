// @author ixxxxoooo
// 客户端接管的斜杠命令:Claude Code 里这些命令是终端 TUI 的界面(/config、/agents、/memory……),
// 经 ACP 到达适配器时没有可用的界面,所以由 OhMyAgent 直接用原生界面实现。
// 本文件只含纯数据逻辑(命令目录、解析、帮助文本),界面动作经 `SessionModel.onLocalCommand` 交给应用层。

import Foundation

/// 由客户端执行的命令。
public enum LocalCommand: Sendable, Equatable {
    /// 开始新对话(`/new`、`/clear`)
    case newConversation
    /// 打开设置页(取值为 `SettingsPage.rawValue`)
    case settings(page: String)
    /// 打开「工具与扩展」的某个分区(取值为 `ExtensionSection.rawValue`)
    case extensions(section: String)
    /// 打开对话内的 MCP 面板
    case mcpPanel
    /// 打开历史会话列表
    case history
    /// 重命名当前会话
    case rename(String)
    /// 把当前对话导出为 Markdown
    case exportTranscript
    /// 显示当前状态(模型、模式、MCP、会话)
    case status
    /// 显示命令帮助
    case help
    /// 打开模型菜单(无参数)
    case modelMenu
    /// 按名称切换模型
    case setModel(String)
    /// 提示账号相关命令由 `claude` 自己管理
    case accountNotice
    /// 交给 Explore 子 Agent 做只读的代码库探索(`/explore <问题>`;问题为空时提示用法)
    case explore(String)
    /// 在新的 Git 工作树里开始一个隔离任务(`/worktree [标题]`)
    case worktree(String)
    /// 把当前工作树的改动合并回原项目(`/apply-worktree`)
    case applyWorktree
    /// 删除当前工作树及其分支(`/delete-worktree`)
    case deleteWorktree
    /// 同一任务交给多个模型,各在独立工作树里并行完成(`/best-of-n 模型1,模型2 任务`)
    case bestOfN(models: [String], task: String)
}

/// 命令目录条目(用于补全菜单与 `/help`)。
public struct LocalCommandSpec: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var hint: String?

    public init(name: String, summary: String, hint: String? = nil) {
        self.name = name
        self.summary = summary
        self.hint = hint
    }
}

/// 客户端命令的目录与解析。
public enum LocalCommands {
    /// 目录:名称(不含 `/`)、说明、参数提示。顺序即补全菜单中同分时的顺序。
    public static let catalog: [LocalCommandSpec] = [
        LocalCommandSpec(name: "new", summary: ChatL10n.t("开始新对话")),
        LocalCommandSpec(name: "clear", summary: ChatL10n.t("清空上下文并开始新对话")),
        LocalCommandSpec(name: "help", summary: ChatL10n.t("列出可用命令与快捷方式")),
        LocalCommandSpec(name: "status", summary: ChatL10n.t("显示模型、模式、MCP 与会话状态")),
        LocalCommandSpec(name: "model", summary: ChatL10n.t("查看或切换模型"), hint: ChatL10n.t("模型名")),
        LocalCommandSpec(name: "config", summary: ChatL10n.t("打开设置")),
        LocalCommandSpec(name: "permissions", summary: ChatL10n.t("管理工具权限规则")),
        LocalCommandSpec(name: "agents", summary: ChatL10n.t("管理子 Agent")),
        LocalCommandSpec(name: "skills", summary: ChatL10n.t("管理 Skills 与自定义命令")),
        LocalCommandSpec(name: "memory", summary: ChatL10n.t("编辑 CLAUDE.md 规则")),
        LocalCommandSpec(name: "hooks", summary: ChatL10n.t("管理 Hooks")),
        LocalCommandSpec(name: "plugin", summary: ChatL10n.t("管理插件")),
        LocalCommandSpec(name: "mcp", summary: ChatL10n.t("管理 MCP 服务器(带参数时由 Agent 执行重连/启用/停用)"), hint: ChatL10n.t("[reconnect|enable|disable [服务器]]")),
        LocalCommandSpec(name: "resume", summary: ChatL10n.t("恢复历史会话")),
        LocalCommandSpec(name: "rename", summary: ChatL10n.t("重命名当前会话"), hint: ChatL10n.t("新名称")),
        LocalCommandSpec(name: "export", summary: ChatL10n.t("把当前对话导出为 Markdown")),
        LocalCommandSpec(name: "doctor", summary: ChatL10n.t("打开诊断页检查安装与配置")),
        LocalCommandSpec(name: "explore", summary: ChatL10n.t("让 Explore 子 Agent 只读检索代码库"), hint: ChatL10n.t("要弄清的问题")),
        LocalCommandSpec(name: "worktree", summary: ChatL10n.t("在新的 Git 工作树里开始隔离任务"), hint: ChatL10n.t("[标题]")),
        LocalCommandSpec(name: "apply-worktree", summary: ChatL10n.t("把当前工作树的改动合并回原项目")),
        LocalCommandSpec(name: "delete-worktree", summary: ChatL10n.t("删除当前工作树及其分支")),
        LocalCommandSpec(name: "best-of-n", summary: ChatL10n.t("多个模型各在独立工作树里完成同一任务,并生成对比"), hint: ChatL10n.t("模型1,模型2 任务")),
        LocalCommandSpec(name: "usage", summary: ChatL10n.t("打开用量与花费统计")),
        LocalCommandSpec(name: "cost", summary: ChatL10n.t("打开用量与花费统计")),
    ]

    /// 目录中的命令名集合。
    public static var names: Set<String> { Set(catalog.map(\.name)) }

    /// `/explore` 发给 Agent 的提示:明确要求用 Explore 子 Agent、只读、返回关键路径。
    /// - Parameter question: 用户的问题
    public static func explorePrompt(_ question: String) -> String {
        "Use the Explore subagent (fast, read-only codebase search) to investigate the question below. Do not modify any files. "
            + "Prefer the `search_code` tool for broad searches. Report the key findings with file paths and line numbers.\n\nQuestion: \(question)"
    }

    /// `/best-of-n` 的参数最多并行的模型数。
    public static let bestOfNLimit = 4

    /// 解析 `/best-of-n` 参数:首个词是逗号分隔的模型名(去重,最多 `bestOfNLimit` 个),其余为任务。
    /// - Parameter argument: 命令后的参数
    /// - Returns: 模型与任务;模型不足 1 个或任务为空时为 nil
    public static func parseBestOfN(_ argument: String) -> (models: [String], task: String)? {
        let parts = argument.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { return nil }
        var models: [String] = []
        for raw in parts[0].split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !models.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { models.append(name) }
        }
        let task = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !models.isEmpty, !task.isEmpty else { return nil }
        return (Array(models.prefix(bestOfNLimit)), task)
    }

    /// 解析输入框文本;不是客户端命令(或带有应交给 Agent 的参数)时返回 nil。
    /// - Parameter text: 用户输入(整条消息)
    /// - Returns: 客户端命令
    public static func parse(_ text: String) -> LocalCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n") else { return nil }
        let body = trimmed.dropFirst()
        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        let name = first.lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "new", "clear", "reset": return argument.isEmpty ? .newConversation : nil
        case "help", "?": return .help
        case "status": return .status
        case "model": return argument.isEmpty ? .modelMenu : .setModel(argument)
        case "config", "settings": return .settings(page: "general")
        case "permissions": return .settings(page: "permissions")
        case "doctor": return .settings(page: "diagnostics")
        case "usage", "cost": return .settings(page: "usage")
        case "agents": return .extensions(section: "agents")
        case "skills": return .extensions(section: "skills")
        case "memory": return .extensions(section: "memory")
        case "hooks": return .extensions(section: "hooks")
        case "plugin", "plugins": return .extensions(section: "plugins")
        // 带参数的 /mcp(reconnect/enable/disable)由适配器经 SDK 控制接口执行
        case "mcp": return argument.isEmpty ? .mcpPanel : nil
        case "resume": return .history
        case "rename": return .rename(argument)
        case "export": return .exportTranscript
        case "login", "logout": return .accountNotice
        case "explore": return .explore(argument)
        case "worktree": return .worktree(argument)
        case "apply-worktree": return .applyWorktree
        case "delete-worktree": return .deleteWorktree
        case "best-of-n": return .bestOfN(models: parseBestOfN(argument)?.models ?? [], task: parseBestOfN(argument)?.task ?? "")
        default: return nil
        }
    }

    /// `/help` 的 Markdown 文本。
    /// - Parameter agentCommandCount: Agent 通告的命令数量
    /// - Returns: Markdown
    public static func helpMarkdown(agentCommandCount: Int) -> String {
        var lines: [String] = [ChatL10n.t("**客户端命令**(由 OhMyAgent 原生界面执行)"), ""]
        for spec in catalog {
            let hint = spec.hint.map { " `\($0)`" } ?? ""
            lines.append("- `/\(spec.name)`\(hint) — \(spec.summary)")
        }
        lines += [
            "",
            ChatL10n.f("**Agent 命令**:输入 `/` 可看到 Agent 通告的全部 %lld 个命令(内置命令、Skills、自定义命令、插件与 MCP 提示),", agentCommandCount),
            ChatL10n.t("例如 `/compact`、`/init`、`/review`、`/goal <目标>`、`/context`。"),
            "",
            ChatL10n.t("**提及**:`@文件` 引用文件;`@agent-名称` 点名某个子 Agent。"),
            "",
            ChatL10n.t("**快捷键**:`⇧Tab` 切换权限模式;运行中 `Return` 把消息引导进当前轮次,`⌘Return` 排到本轮结束后发送;`Esc` 停止。"),
        ]
        return lines.joined(separator: "\n")
    }
}

/// 把对话导出为 Markdown 的纯逻辑(界面负责保存文件)。
public enum TranscriptExporter {
    /// - Parameters:
    ///   - entries: 时间线条目
    ///   - title: 会话标题
    ///   - workspace: 工作区路径
    /// - Returns: Markdown 文本
    @MainActor
    public static func markdown(entries: [TimelineEntry], title: String?, workspace: String) -> String {
        var out: [String] = ["# \(title ?? String(localized: "OhMyAgent 对话"))", "", String(localized: "> 工作区:`\(workspace)`"), ""]
        for entry in entries {
            switch entry.kind {
            case .user:
                out += [String(localized: "## 你"), "", entry.text, ""]
            case .assistant:
                out += ["## Claude", "", entry.text, ""]
            case .thought:
                continue
            case .tool:
                if let tool = entry.tool { out += [String(localized: "- 工具:`\(tool.name ?? tool.title)` — \(tool.title)"), ""] }
            case .plan:
                out += [String(localized: "### 计划"), ""] + entry.plan.map { "- [\($0.status == "completed" ? "x" : " ")] \($0.content)" } + [""]
            case .notice:
                out += ["> \(entry.text)", ""]
            case .changes:
                out += [String(localized: "### 改动"), ""] + entry.changes.map { "- `\($0.path)`" } + [""]
            case .planDoc:
                out += [String(localized: "### 计划"), "", entry.text, ""]
            case .turnSummary:
                out += ["> \(entry.text)", ""]
            case .modelSwitch:
                out += ["> " + String(localized: "模型由 \(entry.text) 切换为 \(entry.detail ?? "")"), ""]
            }
        }
        return out.joined(separator: "\n")
    }
}
