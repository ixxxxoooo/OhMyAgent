// @author ixxxxoooo
// 演示场景:权限请求的变体——删除文件、联网获取、MCP 工具、两个请求同时堆叠。
// 基础的编辑 Diff / Bash / 新建文件见 `permissions` 场景。

import Foundation

extension DemoScenarios {
    /// 权限变体类场景。
    static let permissionScenarios: [DemoScenario] = [
        DemoScenario(id: "permissions-variants", group: "交互", title: "权限请求变体:删除、联网、MCP 与并发堆叠", summary: "删除文件、WebFetch、MCP 工具各一次,最后两个终端命令同时请求,上下堆叠(交互)", behavior: .interactive, build: permissionsVariants),
    ]

    /// 权限请求变体。任一被拒绝即结束本轮。
    static func permissionsVariants(_ c: ScenarioContext) -> [ScenarioStep] {
        let legacy = DemoSteps.path(c, "Sources/AtlasCore/Legacy.swift")
        return DemoSteps.withUsage([
            DemoSteps.say("这一轮会请求几种不同类型的权限:删除、联网、MCP,最后是两个同时发出的命令。\n\n"),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pv_delete", title: "删除 Legacy.swift", kind: "delete", name: "Delete", input: ["file_path": legacy],
                locations: [["path": legacy]]), options: .withAlways, rejectedText: "好的,保留 `Legacy.swift`。")),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pv_fetch", title: "获取 docs.atlas.dev/changelog", kind: "fetch", name: "WebFetch",
                input: ["url": "https://docs.atlas.dev/changelog", "prompt": "列出 0.3 之后的破坏性变更"],
                output: "0.4.0:`Router.register` 的参数顺序调整;`Session.init` 需要显式传入 `router`。"), options: .withAlways)),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pv_mcp", title: "mcp__github__create_issue", kind: "other", name: "mcp__github__create_issue",
                input: ["owner": "ixxxxoooo", "repo": "atlas-web", "title": "路由大小写匹配回归", "labels": ["bug", "router"]],
                output: "Created issue #137: 路由大小写匹配回归"), rejectedText: "好的,不创建 Issue。")),
            DemoSteps.say("接下来两个命令会同时请求权限。\n\n"),
            .parallel([
                [.permission(ScenarioPermission(tool: ScenarioTool(
                    id: "pv_bash1", title: "swift test --filter RouterTests", kind: "execute", name: "Bash",
                    input: ["command": "swift test --filter RouterTests", "description": "运行路由测试"], output: "✔ 3 tests passed"), options: .withAlways))],
                [.permission(ScenarioPermission(tool: ScenarioTool(
                    id: "pv_bash2", title: "git push origin fix/router-case", kind: "execute", name: "Bash",
                    input: ["command": "git push origin fix/router-case", "description": "推送修复分支"], output: "Everything up-to-date"), rejectedText: "好的,先不推送。"))],
            ]),
            DemoSteps.say("所有请求都已处理完毕。\n"),
        ], used: 36_200)
    }
}
