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
        LocalCommandSpec(name: "pr-comments", summary: ChatL10n.t("拉取 Pull Request 上的评论")),
        LocalCommandSpec(name: "context", summary: ChatL10n.t("查看上下文窗口的用量明细")),
        LocalCommandSpec(name: "add-dir", summary: ChatL10n.t("把另一个目录加入工作范围"), hint: ChatL10n.t("目录路径")),
        LocalCommandSpec(name: "output-style", summary: ChatL10n.t("切换输出风格"), hint: ChatL10n.t("[风格]")),
        LocalCommandSpec(name: "rewind", summary: ChatL10n.t("回退对话与代码到之前的检查点")),
        LocalCommandSpec(name: "todos", summary: ChatL10n.t("列出当前的待办事项")),
        LocalCommandSpec(name: "release-notes", summary: ChatL10n.t("查看 Claude Code 的更新说明")),
        LocalCommandSpec(name: "statusline", summary: ChatL10n.t("配置状态栏")),
        LocalCommandSpec(name: "vim", summary: ChatL10n.t("切换 Vim 编辑模式")),
        LocalCommandSpec(name: "terminal-setup", summary: ChatL10n.t("配置终端的换行快捷键")),
        LocalCommandSpec(name: "install-github-app", summary: ChatL10n.t("为仓库安装 Claude GitHub 应用")),
        LocalCommandSpec(name: "bug", summary: ChatL10n.t("反馈问题给 Anthropic")),
        LocalCommandSpec(name: "ide", summary: ChatL10n.t("管理 IDE 集成")),
        LocalCommandSpec(name: "login", summary: ChatL10n.t("登录(由本机 claude 管理)")),
        LocalCommandSpec(name: "logout", summary: ChatL10n.t("退出登录(由本机 claude 管理)")),
    ]

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
