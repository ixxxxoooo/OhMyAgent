// @author ixxxxoooo
// 演示场景:更多内置工具(搜索变体、读取分段、批量替换、沙盒与超时、后台输出与终止、Skill、斜杠命令、
// 延迟工具检索、LSP、定时任务、工作树、联网失败),补齐其它场景没覆盖到的工具形态。

import Foundation

extension DemoScenarios {
    /// 更多内置工具场景。
    static let moreToolScenarios: [DemoScenario] = [
        DemoScenario(id: "tools-more", group: "工具卡", title: "更多内置工具:Skill、LSP、后台输出与定时任务", summary: "Glob 无匹配、Grep 内容模式、分段 Read、replace_all 编辑、沙盒拦截与超时、BashOutput/KillShell、Skill、SlashCommand、ToolSearch、LSP、CronCreate、EnterWorktree、联网失败", build: moreTools),
    ]

    /// 一个只读/杂项工具。
    private static func tool(_ id: String, _ name: String, kind: String, title: String, input: JSONValue, output: String?, finish: ScenarioFinish = .completed) -> ScenarioStep {
        .tool(ScenarioTool(id: id, title: title, kind: kind, name: name, input: input, output: output, finish: finish))
    }

    /// 更多内置工具。
    static func moreTools(_ c: ScenarioContext) -> [ScenarioStep] {
        let old = "    func route(_ request: Request) -> Response {\n        return handlers[request.path]?(request) ?? .notFound\n    }\n"
        return DemoSteps.withUsage([
            DemoSteps.say("这一轮会用到各种不常见的工具,逐个看它们在时间线里长什么样。\n\n"),
            tool("o_glob0", "Glob", kind: "search", title: "查找 Sources/**/*.kt", input: ["pattern": "Sources/**/*.kt"], output: "No files found"),
            tool("o_grep", "Grep", kind: "search", title: "搜索 TODO|FIXME", input: ["pattern": "TODO|FIXME", "path": DemoSteps.path(c, "Sources"), "output_mode": "content", "-n": true, "-C": 1],
                 output: "Sources/AtlasCore/Router.swift:42:    // TODO: 未命中时计数\nSources/AtlasCore/Cache.swift:17:    // FIXME: 过期条目没有清理"),
            DemoSteps.read("o_read", "Sources/AtlasCore/Cache.swift", c, offset: 10, limit: 20, output: (10...29).map { "\($0)\t// 缓存条目 \($0)" }.joined(separator: "\n")),
            DemoSteps.edit("o_edit", "Sources/AtlasCore/Router.swift", c, name: "Edit", old: old, new: old.replacingOccurrences(of: ".notFound", with: ".notFound(request.path)"), line: 40),
            DemoSteps.bash("o_bash_slow", "swift build -c release", description: "发布构建(超时 10 分钟)", output: "Building for production...\nCompiling AtlasCore\nBuild complete! (212.4s)"),
            DemoSteps.bash("o_bash_sandbox", "curl -s https://registry.example.com/health", description: "检查依赖源", output: "curl: (6) Could not resolve host: registry.example.com\n(命令被沙箱拦截:网络访问未被允许)", finish: .failed),
            DemoSteps.bash("o_bg", "npm run dev", description: "后台启动开发服务器", output: "Started in background (id: bash_1)", background: true),
            tool("o_bashout", "BashOutput", kind: "execute", title: "读取后台输出 bash_1", input: ["bash_id": "bash_1"], output: "VITE v5.0.0  ready in 312 ms\n➜  Local:   http://localhost:5173/"),
            tool("o_kill", "KillShell", kind: "other", title: "终止后台任务 bash_1", input: ["shell_id": "bash_1"], output: "Shell bash_1 terminated"),
            tool("o_skill", "Skill", kind: "other", title: "Skill: pdf", input: ["skill": "pdf", "args": "合并 docs 里的三份 PDF"], output: "Launching skill: pdf"),
            tool("o_slash", "SlashCommand", kind: "other", title: "/review", input: ["command": "/review"], output: "Command /review executed"),
            tool("o_toolsearch", "ToolSearch", kind: "search", title: "检索工具 slack send", input: ["query": "slack send", "max_results": 5], output: "mcp__slack__post_message\nmcp__slack__reply_to_thread"),
            tool("o_lsp", "LSP", kind: "other", title: "LSP goToDefinition Router.route", input: ["operation": "goToDefinition", "filePath": DemoSteps.path(c, "Sources/AtlasCore/Router.swift"), "line": 42, "character": 14],
                 output: "Defined in Sources/AtlasCore/Router.swift:38:14"),
            tool("o_cron", "CronCreate", kind: "other", title: "创建定时任务", input: ["cron": "*/30 * * * *", "prompt": "检查 CI 是否通过", "recurring": true], output: "Scheduled job cron_7 (every 30 minutes)"),
            tool("o_wt", "EnterWorktree", kind: "other", title: "进入工作树 fix-router-case", input: ["name": "fix-router-case"], output: "Created worktree at ../atlas-web-fix-router-case on branch fix-router-case"),
            tool("o_fetch_fail", "WebFetch", kind: "fetch", title: "获取 docs.atlas.dev/router", input: ["url": "https://docs.atlas.dev/router", "prompt": "总结路由配置"], output: "Error: 404 Not Found", finish: .failed),
            tool("o_search_dom", "WebSearch", kind: "fetch", title: "联网搜索 atlas router", input: ["query": "atlas web router case sensitivity", "allowed_domains": ["github.com", "swift.org"]],
                 output: "1. Router path matching is case-sensitive — github.com/ixxxxoooo/atlas-web/issues/12\n2. SE-0345 if let shorthand — swift.org"),
            DemoSteps.say("这些工具都已演示:搜索无结果、分段读取、批量编辑、沙盒拦截、后台输出与终止、Skill、斜杠命令、LSP、定时任务、工作树与联网失败。\n"),
        ], used: 58_600)
    }
}
