// @author ixxxxoooo
// 演示用 `~/.claude`:写入沙盒主目录,让设置/扩展页(Skills、命令、Subagent、MCP、Hooks、插件、记忆、权限)都有数据。
// 内容全部是虚构示例,不含任何真实密钥;结构与 ClaudeConfigKit 读取的布局一致。

import Foundation

/// 演示 Claude 配置生成器。
public enum DemoClaudeHome {
    /// 写入演示配置(幂等:已存在则覆盖)。
    /// - Parameters:
    ///   - home: 沙盒主目录
    ///   - atlasPath: atlas-web 项目路径(用于「本地」作用域的 MCP)
    public static func write(home: URL, atlasPath: String) throws {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try put(claude.appendingPathComponent("CLAUDE.md"), memory)
        try writeJSON(claude.appendingPathComponent("settings.json"), settings)
        try writeJSON(home.appendingPathComponent(".claude.json"), claudeJSON(atlasPath: atlasPath))
        for (name, text) in skills { try put(claude.appendingPathComponent("skills/\(name)/SKILL.md"), text) }
        for (name, text) in commands { try put(claude.appendingPathComponent("commands/\(name).md"), text) }
        for (name, text) in agents { try put(claude.appendingPathComponent("agents/\(name).md"), text) }
        try writePlugins(claude: claude)
        try writeJSON(claude.appendingPathComponent("stats-cache.json"), statsCache)
    }

    /// 演示用统计缓存(`stats-cache.json`):固定截止日期与确定性公式生成 30 天活动、每日按模型 token 与按模型累计,
    /// 让「用量与成本」页的图表在演示模式下稳定可见(不依赖真实使用记录)。
    static var statsCache: [String: Any] {
        let models = ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        var activity: [[String: Any]] = []
        var tokens: [[String: Any]] = []
        // 日期:2026-09-16 起连续 30 天
        let start = [2026, 9, 16]
        let monthLengths = [9: 30, 10: 31]
        var year = start[0], month = start[1], dayOfMonth = start[2]
        for index in 0..<30 {
            let date = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
            let weekendDip = (index % 7 == 5 || index % 7 == 6) ? 0.4 : 1.0
            let wave = 0.6 + 0.4 * abs(sin(Double(index) * 0.7))
            let messages = Int((120 * wave * weekendDip).rounded()) + (index * 7) % 23
            activity.append(["date": date, "messageCount": messages, "sessionCount": max(1, messages / 40), "toolCallCount": messages * 2 / 3])
            var byModel: [String: Int] = [:]
            for (modelIndex, model) in models.enumerated() {
                let share = [0.62, 0.28, 0.10][modelIndex]
                byModel[model] = Int(Double(messages) * 5200 * share)
            }
            tokens.append(["date": date, "tokensByModel": byModel])
            dayOfMonth += 1
            if dayOfMonth > (monthLengths[month] ?? 30) { dayOfMonth = 1; month += 1; if month > 12 { month = 1; year += 1 } }
        }
        return [
            "version": 2,
            "lastComputedDate": "2026-10-15",
            "dailyActivity": activity,
            "dailyModelTokens": tokens,
            "modelUsage": [
                "claude-sonnet-4-5": ["inputTokens": 1_820_000, "outputTokens": 640_000, "cacheReadInputTokens": 9_400_000, "cacheCreationInputTokens": 1_100_000, "costUSD": 18.42],
                "claude-opus-4-1": ["inputTokens": 520_000, "outputTokens": 210_000, "cacheReadInputTokens": 2_900_000, "cacheCreationInputTokens": 480_000, "costUSD": 31.7],
                "claude-haiku-4-5": ["inputTokens": 260_000, "outputTokens": 90_000, "cacheReadInputTokens": 700_000, "cacheCreationInputTokens": 90_000, "costUSD": 0.9],
            ],
        ]
    }

    // MARK: 内容

    static let memory = """
    # 个人偏好(演示)

    - 回答用中文,代码注释用中文。
    - 改动前先读相关文件,提交信息使用 Conventional Commits。
    - 不要提交密钥与 `.env` 文件。

    ## 常用命令
    - 构建:`swift build`
    - 测试:`swift test`
    """

    static var settings: [String: Any] { [
        "permissions": [
            "allow": ["Bash(swift build:*)", "Bash(swift test:*)", "Bash(git status:*)", "Bash(git diff:*)", "Read(//tmp/**)"],
            "ask": ["Bash(git push:*)", "Bash(rm:*)"],
            "deny": ["Read(./.env)", "Read(./secrets/**)", "Bash(curl:*)"],
            "defaultMode": "default",
        ],
        "env": ["DISABLE_TELEMETRY": "1", "BASH_DEFAULT_TIMEOUT_MS": "120000"],
        "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo '[hook] 即将执行 Bash 命令' >> /tmp/oma-demo-hook.log"]]]],
            "PostToolUse": [["matcher": "Edit|Write", "hooks": [["type": "command", "command": "echo '[hook] 文件已修改' >> /tmp/oma-demo-hook.log", "timeout": 10]]]],
            "SessionStart": [["hooks": [["type": "command", "command": "echo '[hook] 会话开始' >> /tmp/oma-demo-hook.log"]]]],
        ],
        "enabledPlugins": ["demo-toolkit@oma-demo-market": true, "docs-writer@oma-demo-market": false],
        "includeCoAuthoredBy": false,
    ] }

    static func claudeJSON(atlasPath: String) -> [String: Any] {
        [
            "mcpServers": [
                "github": ["type": "http", "url": "https://api.githubcopilot.com/mcp/"],
                "filesystem": ["type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "env": [String: String]()],
                "sqlite": ["type": "stdio", "command": "uvx", "args": ["mcp-server-sqlite", "--db-path", "/tmp/demo.db"], "env": [String: String]()],
                "design-board": ["type": "sse", "url": "https://example.invalid/sse"],
            ],
            "projects": [
                atlasPath: [
                    "mcpServers": ["atlas-db": ["type": "stdio", "command": "node", "args": ["scripts/db-mcp.js"], "env": ["ATLAS_ENV": "demo"]]],
                    "allowedTools": [String](),
                ],
            ],
        ]
    }

    static let skills: [(String, String)] = [
        ("swift-review", skill("swift-review", "审查 Swift 代码的并发安全、可选值处理与命名规范,给出可执行的修改建议", "## 步骤\n1. 读取改动文件\n2. 检查 Sendable/actor 隔离\n3. 检查强制解包与 try!\n4. 输出按严重度排序的清单")),
        ("release-notes", skill("release-notes", "根据 git log 生成面向用户的发布说明,按新增/修复/改进分组", "## 步骤\n1. `git log --oneline <上一个 tag>..HEAD`\n2. 归并同类提交\n3. 输出 Markdown")),
        ("db-migration", skill("db-migration", "为数据库结构变更生成迁移脚本与回滚脚本,并检查锁表风险", "## 注意\n- 大表加索引使用在线方式\n- 必须同时提供回滚脚本")),
    ]

    static let commands: [(String, String)] = [
        ("review", "---\ndescription: 审查当前未提交的改动\nargument-hint: [关注点]\n---\n请审查当前工作区的未提交改动,重点关注:$ARGUMENTS\n按严重度列出问题并给出修改建议。"),
        ("changelog", "---\ndescription: 生成自上个标签以来的变更日志\n---\n运行 `git log` 汇总自上个 tag 以来的提交,按「新增 / 修复 / 改进」分组输出。"),
        ("standup", "---\ndescription: 生成昨日进展与今日计划\nargument-hint: [天数]\n---\n根据最近 $ARGUMENTS 天的提交生成站会发言稿。"),
    ]

    static let agents: [(String, String)] = [
        ("code-reviewer", "---\nname: code-reviewer\ndescription: 代码审查专家。修改代码后主动使用,检查正确性、并发安全与可维护性\ntools: Read, Grep, Glob, Bash\nmodel: sonnet\n---\n你是一名严格但友善的代码审查员。先看 `git diff`,再逐文件给出具体、可执行的意见。"),
        ("doc-writer", "---\nname: doc-writer\ndescription: 技术文档撰写。为模块生成 README、架构说明与 Mermaid 图\ntools: Read, Write, Glob\nmodel: haiku\n---\n你负责把代码结构整理成清晰的中文文档,必要时用 Mermaid 绘制流程图。"),
        ("test-runner", "---\nname: test-runner\ndescription: 运行测试并分析失败原因,给出最小修复\ntools: Bash, Read, Edit\n---\n运行测试 → 定位失败 → 提出最小修复 → 再次运行确认。"),
    ]

    private static func skill(_ name: String, _ description: String, _ body: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n\n\(body)\n"
    }

    // MARK: 插件

    private static func writePlugins(claude: URL) throws {
        let market = "oma-demo-market"
        let plugins = claude.appendingPathComponent("plugins", isDirectory: true)
        let toolkit = plugins.appendingPathComponent("cache/\(market)/demo-toolkit/1.2.0", isDirectory: true)
        let docs = plugins.appendingPathComponent("cache/\(market)/docs-writer/0.4.1", isDirectory: true)
        try writeJSON(toolkit.appendingPathComponent(".claude-plugin/plugin.json"), ["name": "demo-toolkit", "version": "1.2.0", "description": "演示工具箱:一组常用的 Skill、命令与 Subagent", "author": ["name": "OhMyAgent Demo"]])
        try put(toolkit.appendingPathComponent("skills/toolkit-tips/SKILL.md"), skill("toolkit-tips", "演示插件内的 Skill", "插件内置技能,只读展示。"))
        try put(toolkit.appendingPathComponent("agents/toolkit-helper.md"), "---\nname: toolkit-helper\ndescription: 插件内的演示 Subagent\n---\n你是演示插件里的助手。")
        try put(toolkit.appendingPathComponent("commands/toolkit-hello.md"), "---\ndescription: 插件内的演示命令\n---\n向用户问好并列出可用的工具箱功能。")
        try writeJSON(toolkit.appendingPathComponent("hooks/hooks.json"), ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "echo toolkit"]]]]]])
        try writeJSON(toolkit.appendingPathComponent(".mcp.json"), ["mcpServers": ["toolkit-mcp": ["command": "node", "args": ["server.js"]]]])
        try writeJSON(docs.appendingPathComponent(".claude-plugin/plugin.json"), ["name": "docs-writer", "version": "0.4.1", "description": "演示文档插件(默认停用)", "author": "Docs Team"])
        try put(docs.appendingPathComponent("skills/api-docs/SKILL.md"), skill("api-docs", "生成 API 文档", "根据代码注释生成 API 文档。"))
        let stamp = "2026-10-01T08:00:00.000Z"
        try writeJSON(plugins.appendingPathComponent("installed_plugins.json"), [
            "version": 2,
            "plugins": [
                "demo-toolkit@\(market)": [["scope": "user", "installPath": toolkit.path, "version": "1.2.0", "installedAt": stamp, "lastUpdated": stamp]],
                "docs-writer@\(market)": [["scope": "user", "installPath": docs.path, "version": "0.4.1", "installedAt": stamp, "lastUpdated": stamp]],
            ],
        ])
        try writeJSON(plugins.appendingPathComponent("known_marketplaces.json"), [
            market: ["source": ["source": "github", "repo": "oma-demo/market"], "installLocation": plugins.appendingPathComponent("marketplaces/\(market)").path, "lastUpdated": stamp],
        ])
    }

    // MARK: 写文件

    private static func put(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeJSON(_ url: URL, _ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
