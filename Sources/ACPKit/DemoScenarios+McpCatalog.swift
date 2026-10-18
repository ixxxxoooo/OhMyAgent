// @author ixxxxoooo
// 演示场景:MCP 服务器全家福(文档/协作/数据/设计/浏览器/记忆/基础设施)、MCP 资源与各种失败形态。
// 每个 MCP 调用的工具名都是 Claude Code 风格的 `mcp__服务器__工具`,用来检查工具行、分组摘要、详情与失败样式。

import Foundation

extension DemoScenarios {
    /// MCP 目录类场景。
    static let mcpCatalogScenarios: [DemoScenario] = [
        DemoScenario(id: "mcp-servers", group: "工具卡", title: "MCP 全家福:二十个常见服务器的调用", summary: "context7、brave-search、fetch、github、sentry、linear、jira、notion、slack、postgres、sqlite、supabase、figma、chrome-devtools(截图)、memory、sequential-thinking、kubernetes、stripe 等,含超长 JSON 与 Markdown 结果", build: mcpServers),
        DemoScenario(id: "mcp-failures", group: "工具卡", title: "MCP 失败与资源:鉴权、超时、限流与资源读取", summary: "未授权、连接超时、限流、参数校验失败、服务器未启动,以及 ListMcpResources / ReadMcpResource", build: mcpFailures),
    ]

    /// 一个 MCP 调用(`mcp__服务器__工具`)。
    private static func mcp(_ id: String, _ server: String, _ tool: String, _ input: JSONValue, _ output: String,
                            finish: ScenarioFinish = .completed, extra: [JSONValue] = []) -> ScenarioStep {
        let name = "mcp__\(server)__\(tool)"
        return .tool(ScenarioTool(id: id, title: name, kind: "other", name: name, input: input, output: output, extra: extra, finish: finish))
    }

    /// 二十个常见 MCP 服务器。
    static func mcpServers(_ c: ScenarioContext) -> [ScenarioStep] {
        let bigJSON = "{\"rows\": [" + (1...24).map { "{\"id\": \($0), \"route\": \"/api/v1/items/\($0)\", \"p95_ms\": \(40 + $0 * 3), \"errors\": \($0 % 5)}" }.joined(separator: ", ") + "], \"total\": 24}"
        let markdown = "# Router 迁移指南\n\n## 步骤\n1. 开启严格并发\n2. 修复 `Sendable` 诊断\n3. 切换语言模式\n\n> 注意:先在 CI 里跑一轮再合并。"
        return DemoSteps.withUsage([
            DemoSteps.say("我把这次排查会用到的外部系统都查一遍:文档、工单、监控、数据库、设计稿与浏览器。\n\n"),
            .thought(["先查文档与搜索,", "再看工单与监控,", "最后核对数据与页面。"]),
            mcp("m_c7a", "context7", "resolve-library-id", ["libraryName": "swiftui"], "Selected: /apple/swiftui (Trust 9.8, 1,204 snippets)"),
            mcp("m_c7b", "context7", "get-library-docs", ["context7CompatibleLibraryID": "/apple/swiftui", "topic": "LazyVStack", "tokens": 5000], markdown),
            mcp("m_brave", "brave-search", "brave_web_search", ["query": "SwiftUI LazyVStack scroll hitch", "count": 5],
                "1. Diagnosing hitches in scrolling views — Apple\n2. LazyVStack vs List performance — swiftbysundell\n3. Why is my LazyVStack slow? — StackOverflow"),
            mcp("m_fetch", "fetch", "fetch", ["url": "https://developer.apple.com/documentation/swiftui/lazyvstack", "max_length": 5000], markdown),
            mcp("m_gh1", "github", "get_pull_request", ["owner": "ixxxxoooo", "repo": "atlas-web", "pull_number": 131],
                "{\"number\": 131, \"title\": \"fix: 路由大小写\", \"state\": \"open\", \"mergeable\": true, \"additions\": 24, \"deletions\": 6, \"changed_files\": 3}"),
            mcp("m_gh2", "github", "search_code", ["q": "metrics.count repo:ixxxxoooo/atlas-web"],
                "{\"total_count\": 3, \"items\": [{\"path\": \"Sources/AtlasCore/Router.swift\"}, {\"path\": \"Sources/AtlasCore/Session.swift\"}, {\"path\": \"Tests/RouterTests.swift\"}]}"),
            mcp("m_gh3", "github", "create_pull_request_review", ["owner": "ixxxxoooo", "repo": "atlas-web", "pull_number": 131, "event": "COMMENT", "body": "路由归一化逻辑看起来没问题,建议补一条大小写混合的用例。"], "Review submitted (id: 88123)"),
            mcp("m_sentry", "sentry", "get_issue_details", ["issueId": "ATLAS-4F2"],
                "ATLAS-4F2 · RouterError.notFound · 148 events · 31 users · first seen 2 days ago · regression in 1.4.2"),
            mcp("m_linear1", "linear", "list_issues", ["team": "Atlas", "assignee": "me", "state": "In Progress"],
                "ATL-212 路由未命中指标缺失 (In Progress)\nATL-219 会话超时配置化 (In Progress)"),
            mcp("m_linear2", "linear", "create_issue", ["team": "Atlas", "title": "补充大小写混合路由的单元测试", "priority": 3], "Created ATL-231"),
            mcp("m_jira", "jira", "get_issue", ["issueKey": "ATLAS-77"], "ATLAS-77 · Bug · Medium · Router drops trailing slash · Reporter: mei"),
            mcp("m_notion", "notion", "search", ["query": "路由设计文档", "filter": ["property": "object", "value": "page"]],
                "- 路由设计文档 v2 (更新于 3 天前)\n- 路由迁移计划 (更新于 2 周前)"),
            mcp("m_slack", "slack", "post_message", ["channel": "#atlas-dev", "text": "路由大小写问题已定位,修复 PR 稍后提交。"], "Message posted (ts: 1760780412.004200)"),
            mcp("m_pg", "postgres", "query", ["sql": "SELECT route, p95_ms, errors FROM route_stats ORDER BY p95_ms DESC LIMIT 24"], bigJSON),
            mcp("m_sqlite", "sqlite", "read_query", ["query": "SELECT COUNT(*) AS n FROM sessions WHERE expired = 1"], "[{\"n\": 17}]"),
            mcp("m_supa", "supabase", "list_tables", ["schemas": ["public"]], "public.sessions, public.route_stats, public.users"),
            mcp("m_figma", "figma", "get_file", ["fileKey": "AbC123xYz", "depth": 2], "File: Atlas Dashboard · 6 pages · last modified yesterday"),
            mcp("m_cdt", "chrome-devtools", "take_screenshot", ["format": "png"], "Took a screenshot of the current page's viewport.",
                extra: [["type": "content", "content": ScenarioImages.contentBlock(.dashboard)]]),
            mcp("m_mem", "memory", "create_entities", ["entities": [["name": "Router", "entityType": "module", "observations": ["未命中时需要计数"]]]], "Created 1 entity"),
            mcp("m_seq", "sequential-thinking", "sequentialthinking", ["thought": "先确认指标口径,再决定放在 Router 还是中间件", "thoughtNumber": 1, "totalThoughts": 3, "nextThoughtNeeded": true], "{\"thoughtNumber\": 1, \"totalThoughts\": 3, \"nextThoughtNeeded\": true}"),
            mcp("m_k8s", "kubernetes", "get_pods", ["namespace": "atlas", "labelSelector": "app=router"], "router-7d9f8b6c5-x2k4p   Running   0 restarts   3d\nrouter-7d9f8b6c5-q8m7n   Running   1 restarts   3d"),
            mcp("m_stripe", "stripe", "list_customers", ["limit": 3], "cus_Q1 (mei@example.com), cus_Q2 (lee@example.com), cus_Q3 (ann@example.com)"),
            DemoSteps.say("汇总:ATL-212 与 Sentry 的 ATLAS-4F2 是同一个问题(路由未命中),PR #131 已评审,数据库里 `route_stats` 的 p95 最高的是 `/api/v1/items/24`。\n"),
        ], used: 66_400)
    }

    /// MCP 失败形态与资源读取。
    static func mcpFailures(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.say("这些调用会各自以不同方式失败,另外读取两个 MCP 资源。\n\n"),
            mcp("x_auth", "github", "create_issue", ["owner": "ixxxxoooo", "repo": "atlas-web", "title": "路由未命中没有指标"],
                "Error: 401 Bad credentials — 请重新授权 GitHub MCP 服务器", finish: .failed),
            mcp("x_timeout", "postgres", "query", ["sql": "SELECT * FROM huge_audit_log"], "Error: MCP error -32001: Request timed out after 60000ms", finish: .failed),
            mcp("x_rate", "brave-search", "brave_web_search", ["query": "swift concurrency"], "Error: 429 Too Many Requests — retry after 30s", finish: .failed),
            mcp("x_schema", "linear", "create_issue", ["title": 42], "Error: Invalid arguments: `team` is required; `title` must be a string", finish: .failed),
            mcp("x_down", "sentry", "get_issue_details", ["issueId": "ATLAS-4F2"], "Error: MCP server \"sentry\" is not connected (spawn npx ENOENT)", finish: .failed),
            .tool(ScenarioTool(id: "x_list", title: "ListMcpResourcesTool", kind: "other", name: "ListMcpResourcesTool", input: ["server": "filesystem"],
                               output: "file:///Users/demo/atlas-web/README.md (text/markdown)\nfile:///Users/demo/atlas-web/Package.swift (text/x-swift)")),
            .tool(ScenarioTool(id: "x_read", title: "ReadMcpResourceTool", kind: "other", name: "ReadMcpResourceTool",
                               input: ["server": "filesystem", "uri": "file:///Users/demo/atlas-web/README.md"],
                               output: "# atlas-web\n\n一个演示用的 Swift 服务端项目。")),
            .tool(ScenarioTool(id: "x_slow", title: "mcp__figma__get_file", kind: "other", name: "mcp__figma__get_file", input: ["fileKey": "AbC123xYz"],
                               output: nil, finish: .running)),
            DemoSteps.say("五个失败各有不同原因:未授权、超时、限流、参数不合法、服务器没启动;两个资源读取成功。\n"),
        ], used: 31_200)
    }
}
