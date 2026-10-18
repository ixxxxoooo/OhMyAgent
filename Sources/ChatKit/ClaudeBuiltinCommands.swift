// @author ixxxxoooo
// Claude Code 内置斜杠命令的静态清单:连接 Agent 之前(或适配器没有通告命令时)也能在补全里看到,
// 连接后以适配器通告的列表为准(同名去重)。这些命令由 Agent 执行,客户端不接管。

import Foundation

/// Claude Code 内置命令清单。
public enum ClaudeBuiltinCommands {
    /// 清单条目:名称(不含 `/`)、说明、参数提示。
    public static let catalog: [LocalCommandSpec] = [
        LocalCommandSpec(name: "compact", summary: ChatL10n.t("压缩对话历史,可附带压缩重点"), hint: ChatL10n.t("[压缩说明]")),
        LocalCommandSpec(name: "init", summary: ChatL10n.t("分析项目并生成 CLAUDE.md")),
        LocalCommandSpec(name: "review", summary: ChatL10n.t("评审一个 Pull Request"), hint: ChatL10n.t("[PR 编号]")),
        LocalCommandSpec(name: "security-review", summary: ChatL10n.t("对当前分支的改动做安全评审")),
        LocalCommandSpec(name: "context", summary: ChatL10n.t("查看上下文窗口的用量明细")),
        LocalCommandSpec(name: "output-style", summary: ChatL10n.t("切换输出风格"), hint: ChatL10n.t("[风格]")),
        LocalCommandSpec(name: "effort", summary: ChatL10n.t("设置思考强度"), hint: "low|medium|high|xhigh|max|auto"),
        LocalCommandSpec(name: "autocompact", summary: ChatL10n.t("查看或设置自动压缩的窗口")),
        LocalCommandSpec(name: "login", summary: ChatL10n.t("登录(由本机 claude 管理)")),
        LocalCommandSpec(name: "logout", summary: ChatL10n.t("退出登录(由本机 claude 管理)")),
    ]

    /// 经适配器实测不可用的内置命令(依赖终端界面,或当前版本已不存在)→ 说明文字。
    /// 不进补全菜单;手动输入时由客户端直接给出说明,不再发给 Agent(避免被当成普通提问白白消耗用量)。
    public static let unsupported: [String: String] = [
        "add-dir": ChatL10n.t("`/add-dir` 依赖终端界面。想把多个目录放进同一个工作区,请在工作区编辑里用「添加文件夹…」。"),
        "rewind": ChatL10n.t("`/rewind` 依赖终端界面。想回退改动,请用每轮结束后的「本轮改动」卡片回退到检查点。"),
        "todos": ChatL10n.t("`/todos` 依赖终端界面。待办会显示在输入框上方的「待办」卡片里。"),
        "pr-comments": ChatL10n.t("当前 Claude Code 版本已没有 `/pr-comments`。可以直接让 Agent 用 GitHub MCP 或 `gh` 拉取 PR 评论。"),
        "release-notes": ChatL10n.t("`/release-notes` 只在终端里可用。"),
        "statusline": ChatL10n.t("`/statusline` 是终端状态栏的配置,在 OhMyAgent 里不可用。"),
        "vim": ChatL10n.t("`/vim` 是终端输入框的编辑模式,在 OhMyAgent 里不可用。"),
        "terminal-setup": ChatL10n.t("`/terminal-setup` 是终端的快捷键配置,在 OhMyAgent 里不可用。"),
        "ide": ChatL10n.t("`/ide` 是终端里的 IDE 集成,在 OhMyAgent 里不可用。"),
        "install-github-app": ChatL10n.t("`/install-github-app` 依赖终端界面,请在终端里运行 `claude` 后执行。"),
        "bug": ChatL10n.t("`/bug` 依赖终端界面,请在终端里运行 `claude` 后执行。"),
    ]

    /// 适配器通告了、但在 OhMyAgent 里没有意义的命令(内部命令、SDK 下不可用),补全菜单里隐藏。
    public static let hiddenFromCompletion: Set<String> = ["fast", "workflow-launch-exec"]

    /// 清单转补全候选(类别为 Agent 命令,徽标「Claude Code」,不含与 `exclude` 重名的项)。
    /// - Parameter exclude: 已存在的命令名(不含 `/`)
    /// - Returns: 补全候选
    public static func items(excluding exclude: Set<String>) -> [CompletionItem] {
        catalog.filter { !exclude.contains($0.name) }.map { spec in
            CompletionItem(kind: .agentCommand, title: "/\(spec.name)" + (spec.hint.map { " <\($0)>" } ?? ""),
                           subtitle: spec.summary, insertText: "/\(spec.name)", badge: "Claude Code")
        }
    }
}
