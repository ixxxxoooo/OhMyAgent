// @author ixxxxoooo
// 演示场景:子代理的完整生命周期(启动中 → 运行中 → 完成,卡片上的待办计数与当前活动实时变化),
// 以及 Await 工具(等后台命令与后台子代理结束,或等输出里出现 Ready / Error)。

import Foundation

extension DemoScenarios {
    /// 生命周期与等待类场景。
    static let lifecycleScenarios: [DemoScenario] = [
        DemoScenario(id: "subagents-lifecycle", group: "子 Agent", title: "子代理生命周期:启动中、运行中与完成", summary: "三个子代理同时派发,卡片依次经历「启动中 → 运行中(待办计数、当前活动)→ 已完成」,父对话显示「等待子代理」", build: subagentsLifecycle),
        DemoScenario(id: "subagents-cards", group: "子 Agent", title: "子代理卡片:五种状态同时停住", summary: "启动中、运行中(待办计数 + 当前活动)、后台运行、已完成、已失败各一张卡片,父对话停在「等待子代理」(冻结,需取消)", behavior: .frozen, build: subagentsCards),
        DemoScenario(id: "await-tasks", group: "工具卡", title: "Await:等待后台命令与后台子代理", summary: "后台启动开发服务器与文档子代理,Await 一直等到两者就绪(输出出现 Ready)再继续", build: awaitTasks),
    ]

    /// 待办条目(进度由状态数组给出)。
    private static func todoPlan(_ names: [String], _ states: [String]) -> ScenarioStep {
        .plan(zip(names, states).map { ScenarioPlanItem($0, priority: "high", status: $1) })
    }

    /// 子代理生命周期。
    static func subagentsLifecycle(_ c: ScenarioContext) -> [ScenarioStep] {
        let explore = ["定位路由入口", "梳理中间件链", "整理调用关系"]
        let review = ["检查锁的使用", "检查共享状态", "给出修改建议"]
        let regression = ["运行路由测试", "运行会话测试"]
        let router = DemoSteps.path(c, "Sources/AtlasCore/Router.swift")
        return DemoSteps.withUsage([
            DemoSteps.say("这个任务可以拆成三块并行处理,我同时派发三个子代理。\n\n"),
            .parallel([
                [.subagent(ScenarioSubagent(
                    id: "lc_explore", title: "梳理路由与中间件", agentType: "Explore",
                    children: [
                        .thought(["先找到路由的入口。"]),
                        todoPlan(explore, ["in_progress", "pending", "pending"]),
                        .tool(ScenarioTool(id: "lc_e_grep", title: "搜索 handlers", kind: "search", name: "Grep", input: ["pattern": "handlers", "path": DemoSteps.path(c, "Sources")],
                                           output: "\(c.cwd)/Sources/AtlasCore/Router.swift:5:    private var handlers: [String: (Request) -> Response] = [:]", holdMillis: 500)),
                        todoPlan(explore, ["completed", "in_progress", "pending"]),
                        DemoSteps.read("lc_e_read", "Sources/AtlasCore/Router.swift", c, output: "final class Router { ... }"),
                        todoPlan(explore, ["completed", "completed", "in_progress"]),
                        .text(["路由通过字典分发,", "没有中间件链,调用方直接依赖 Router。"]),
                        todoPlan(explore, ["completed", "completed", "completed"]),
                    ],
                    result: "路由通过字典分发,没有中间件链;Session 在第 48 行调用 route。"
                ))],
                [.subagent(ScenarioSubagent(
                    id: "lc_review", title: "审查并发安全", agentType: "code-reviewer",
                    children: [
                        .delay(1800),
                        .thought(["Router 的 handlers 是可变字典,", "需要确认注册与路由是否在同一线程。"]),
                        todoPlan(review, ["in_progress", "pending", "pending"]),
                        .tool(ScenarioTool(id: "lc_r_read", title: "读取 Router.swift", kind: "read", name: "Read", input: ["file_path": router],
                                           output: "final class Router { private var handlers ... }", holdMillis: 700)),
                        todoPlan(review, ["completed", "in_progress", "pending"]),
                        .tool(ScenarioTool(id: "lc_r_grep", title: "搜索 register(", kind: "search", name: "Grep", input: ["pattern": "register\\(", "path": DemoSteps.path(c, "Sources")],
                                           output: "\(c.cwd)/Sources/AtlasCore/Session.swift:21:        router.register(\"/\", home)", holdMillis: 700)),
                        todoPlan(review, ["completed", "completed", "in_progress"]),
                        .text(["注册只发生在启动阶段,", "运行期只读,目前没有并发写入风险。"]),
                        todoPlan(review, ["completed", "completed", "completed"]),
                    ],
                    result: "注册只在启动阶段发生,运行期只读;当前没有并发写入风险。"
                ))],
                [.subagent(ScenarioSubagent(
                    id: "lc_test", title: "运行回归测试", agentType: "general-purpose",
                    children: [
                        .delay(3200),
                        todoPlan(regression, ["in_progress", "pending"]),
                        DemoSteps.bash("lc_t_router", "swift test --filter RouterTests", description: "运行路由测试", output: "✔ 3 tests passed"),
                        todoPlan(regression, ["completed", "in_progress"]),
                        DemoSteps.bash("lc_t_session", "swift test --filter SessionTests", description: "运行会话测试", output: "✔ 5 tests passed"),
                        todoPlan(regression, ["completed", "completed"]),
                        .text(["两组测试全部通过。"]),
                    ],
                    result: "RouterTests 3 项、SessionTests 5 项全部通过。"
                ))],
            ]),
            DemoSteps.say("三个子代理都已完成:路由结构清晰、没有并发写入风险,回归测试全部通过。\n"),
        ], used: 88_400)
    }

    /// Await:等后台命令与后台子代理。
    static func awaitTasks(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("先在后台启动开发服务器,同时让一个子代理生成接口文档,然后等两者都就绪。\n\n"),
            DemoSteps.bash("aw_dev", "npm run dev", description: "后台启动开发服务器", output: "Started in background (id: bg_dev)", background: true),
            .parallel([
                [.subagent(ScenarioSubagent(
                    id: "aw_doc", title: "生成接口文档", agentType: "general-purpose", background: true,
                    children: [
                        .delay(1500),
                        .thought(["先列出公开接口,再逐个写说明。"]),
                        .tool(ScenarioTool(id: "aw_d_glob", title: "查找 Sources/**/*.swift", kind: "search", name: "Glob", input: ["pattern": "Sources/**/*.swift"],
                                           output: "\(c.cwd)/Sources/AtlasCore/Router.swift", holdMillis: 600)),
                        .text(["接口文档已生成到 docs/api.md。"]),
                    ],
                    result: "接口文档已生成到 docs/api.md。"
                ))],
                [.tool(ScenarioTool(
                    id: "aw_wait", title: "等待后台任务", kind: "other", name: "Await",
                    input: ["task_ids": ["bg_dev", "aw_doc"], "pattern": "Ready|Error", "timeout_ms": 30_000],
                    output: "bg_dev:输出出现 \"Ready\"(VITE v5.0.0  ready in 312 ms)\naw_doc:已完成", holdMillis: 3600
                ))],
            ]),
            DemoSteps.say("开发服务器已就绪,接口文档也生成好了,可以继续联调。\n"),
        ]
    }

    /// 五种卡片状态同时停住。
    static func subagentsCards(_ c: ScenarioContext) -> [ScenarioStep] {
        let todos = ["检查锁的使用", "检查共享状态", "给出修改建议"]
        return [
            DemoSteps.say("同时派发五个子代理,卡片会各自停在不同的状态。\n\n"),
            .subagent(ScenarioSubagent(
                id: "sc_done", title: "梳理路由入口", agentType: "Explore",
                children: [
                    todoPlan(["定位入口", "整理调用关系"], ["completed", "completed"]),
                    DemoSteps.read("sc_d_read", "Sources/AtlasCore/Router.swift", c, output: "final class Router { ... }"),
                    .text(["入口在 Router.route。"]),
                ],
                result: "入口在 Router.route,由 Session 调用。"
            )),
            .subagent(ScenarioSubagent(
                id: "sc_running", title: "审查并发安全", agentType: "code-reviewer",
                children: [
                    .thought(["Router 的 handlers 是可变字典,", "需要确认注册与路由是否在同一线程。"]),
                    todoPlan(todos, ["completed", "in_progress", "pending"]),
                    .tool(ScenarioTool(id: "sc_r_read", title: "读取 Session.swift", kind: "read", name: "Read",
                                       input: ["file_path": DemoSteps.path(c, "Sources/AtlasCore/Session.swift")], finish: .running)),
                ],
                finish: .running
            )),
            .subagent(ScenarioSubagent(id: "sc_starting", title: "运行回归测试", agentType: "general-purpose", children: [], finish: .running)),
            .subagent(ScenarioSubagent(
                id: "sc_background", title: "生成接口文档(后台)", agentType: "general-purpose", background: true,
                children: [.thought(["先列出公开接口,再逐个写说明。"])],
                finish: .running
            )),
            .subagent(ScenarioSubagent(
                id: "sc_failed", title: "检查文档站点链接", agentType: "general-purpose",
                children: [
                    .tool(ScenarioTool(id: "sc_f_fetch", title: "获取 docs.atlas.dev", kind: "fetch", name: "WebFetch", input: ["url": "https://docs.atlas.dev"],
                                       output: "getaddrinfo ENOTFOUND docs.atlas.dev", finish: .failed)),
                    .text(["域名无法解析,放弃。"]),
                ],
                finish: .failed, result: "无法访问 docs.atlas.dev,检查未完成。"
            )),
            .hold,
        ]
    }
}
