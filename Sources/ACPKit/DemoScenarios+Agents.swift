// @author ixxxxoooo
// 演示场景:子 Agent(多类型/嵌套/并行/后台/失败)、会话状态(等待/冻结/提示/错误/用量)、角色样式、全量串联。

import Foundation

extension DemoScenarios {
    /// 子 Agent 与状态类场景。
    static let agentScenarios: [DemoScenario] = [
        DemoScenario(id: "subagents", group: "子 Agent", title: "子 Agent:代码审查与调研", summary: "Explore / code-reviewer / general-purpose、两层嵌套、失败的子 Agent", build: subagents),
        DemoScenario(id: "subagents-parallel", group: "子 Agent", title: "并行子 Agent:同时审查三个模块", summary: "三个子 Agent 同时运行,一个失败,一个转入后台", build: subagentsParallel),
        DemoScenario(id: "subagents-background", group: "子 Agent", title: "后台子 Agent:持续运行的调研", summary: "子 Agent 在后台保持运行,用于任务坞的「子 Agent」面板", build: subagentsBackground),
        DemoScenario(id: "states-working", group: "状态与错误", title: "运行中:长思考、引导与排队", summary: "长时间思考后保持运行(冻结),可测试发送引导、排队消息、/goal 与取消", behavior: .frozen, build: statesWorking),
        DemoScenario(id: "states-frozen", group: "状态与错误", title: "冻结态:待处理与进行中的工具", summary: "待处理、进行中的工具与子 Agent 停在原地,用于检查转圈与样式", behavior: .frozen, build: statesFrozen),
        DemoScenario(id: "states-notices", group: "状态与错误", title: "提示与用量:额度回退与上下文告急", summary: "info/warning/error 三级提示、第三方 TPS 通知行、上下文接近上限、标题与模式更新", build: statesNotices),
        DemoScenario(id: "states-errors", group: "状态与错误", title: "失败:工具、子 Agent 与错误提示", summary: "失败的工具(终端/编辑/MCP)、失败的子 Agent、错误提示", build: statesErrors),
        DemoScenario(id: "states-streaming", group: "状态与错误", title: "长输出:流式渲染与滚动跟随", summary: "较长的流式文本,用于检查滚动跟随与渲染性能", build: statesStreaming),
        DemoScenario(id: "roles", group: "会话流样式", title: "角色样式:所有条目同屏", summary: "用户/助手/思维/计划/各级提示/计划文档同屏对比", build: roles),
        DemoScenario(id: "terminal", group: "工具卡", title: "内嵌终端:在客户端终端运行命令", summary: "通过客户端终端执行命令(需在设置里开启「终端」能力)", build: terminal),
        DemoScenario(id: "long-running", group: "状态与错误", title: "长时间任务:终端与后台子 Agent", summary: "约 20 秒的终端与未完成的子 Agent,任务坞三个分区同时有数据", build: longRunning),
        DemoScenario(id: "all", group: "回归", title: "全量回归:依次运行所有自动场景", summary: "依次运行全部自动场景(跳过终端/长占用/慢速输出),用于一次性回归", build: runAll),
    ]

    // MARK: 子 Agent

    /// 多种类型的子 Agent:Explore、code-reviewer、general-purpose(含两层嵌套)、失败。
    static func subagents(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            .thought(["这个任务可以拆给几个", "专门的子 Agent 并行调研。"]),
            DemoSteps.say("我先让 Explore 子 Agent 摸清代码结构。\n\n"),
            .subagent(ScenarioSubagent(
                id: "a_explore", title: "探索路由与会话模块", agentType: "Explore",
                children: [
                    .thought(["先找路由入口。"]),
                    .tool(ScenarioTool(id: "a_e_grep", title: "搜索 handlers", kind: "search", name: "Grep", input: ["pattern": "handlers", "path": DemoSteps.path(c, "Sources")],
                                       output: "\(c.cwd)/Sources/AtlasCore/Router.swift:5:    private var handlers: [String: (Request) -> Response] = [:]")),
                    DemoSteps.read("a_e_read", "Sources/AtlasCore/Router.swift", c, output: "final class Router { ... }"),
                    .text(["Router 通过字典保存处理函数,", "未命中时直接返回 .notFound。"]),
                ],
                result: "Router 通过字典保存处理函数;Session 在 48 行调用 route。"
            )),
            DemoSteps.say("接着让 code-reviewer 审查最近的改动,它会再委派一个通用子 Agent 跑测试。\n\n"),
            .subagent(ScenarioSubagent(
                id: "a_review", title: "审查最近提交的改动", agentType: "code-reviewer",
                children: [
                    DemoSteps.bash("a_r_diff", "git diff HEAD~1 --stat", output: " Sources/AtlasCore/Router.swift | 8 +++++---\n 1 file changed, 5 insertions(+), 3 deletions(-)"),
                    .subagent(ScenarioSubagent(
                        id: "a_review_test", title: "运行受影响的测试", agentType: "general-purpose",
                        children: [
                            DemoSteps.bash("a_r_test", "swift test --filter RouterTests", output: "✔ 2 tests passed"),
                            .text(["测试全部通过。"]),
                        ],
                        result: "RouterTests 2 项全部通过。"
                    )),
                    .text(["发现一处可改进:", "未命中时没有日志。"]),
                ],
                result: "整体良好;建议在未命中时补充日志。"
            )),
            DemoSteps.say("最后一个子 Agent 去检查文档链接,但它会失败。\n\n"),
            .subagent(ScenarioSubagent(
                id: "a_docs", title: "检查文档链接", agentType: "general-purpose",
                children: [
                    .tool(ScenarioTool(id: "a_d_fetch", title: "获取 docs.atlas.dev", kind: "fetch", name: "WebFetch", input: ["url": "https://docs.atlas.dev"], output: "getaddrinfo ENOTFOUND docs.atlas.dev", finish: .failed)),
                    .text(["域名无法解析,放弃。"]),
                ],
                finish: .failed,
                result: "无法访问 docs.atlas.dev,检查未完成。"
            )),
            DemoSteps.say("总结:路由结构清晰,改动已通过测试,文档站点当前不可达。\n"),
        ], used: 96_400)
    }

    /// 并行子 Agent:三个同时运行(一个失败),另有一个转入后台持续运行。
    static func subagentsParallel(_ c: ScenarioContext) -> [ScenarioStep] {
        func explorer(_ id: String, _ title: String, _ pattern: String, finish: ScenarioFinish = .completed) -> ScenarioStep {
            .subagent(ScenarioSubagent(
                id: id, title: title, agentType: "Explore",
                children: [
                    .tool(ScenarioTool(id: id + "_grep", title: "搜索 " + pattern, kind: "search", name: "Grep", input: ["pattern": .string(pattern)], output: "\(c.cwd)/Sources/AtlasCore/Cache.swift:3:// \(pattern)")),
                    .delay(120),
                    .text(["完成对 \(pattern) 的调研。"]),
                ],
                finish: finish,
                result: finish == .failed ? "调研失败:索引不可用。" : "找到 3 处相关代码。"
            ))
        }
        return DemoSteps.withUsage([
            DemoSteps.say("我同时启动三个调研,再把耗时较长的一个放到后台。\n\n"),
            .parallel([
                [explorer("a_p1", "调研缓存策略", "cache")],
                [explorer("a_p2", "调研会话生命周期", "session")],
                [explorer("a_p3", "调研指标上报", "metrics", finish: .failed)],
            ]),
            .subagent(ScenarioSubagent(
                id: "a_bg", title: "全量依赖审计(后台)", agentType: "general-purpose", background: true,
                children: [DemoSteps.bash("a_bg_audit", "swift package show-dependencies", output: "atlas-web\n└── SwiftTerm 1.5.1")],
                finish: .running
            )),
            DemoSteps.say("三个调研已汇总;依赖审计转入后台,完成后会通知。\n"),
        ], used: 71_000)
    }

    /// 后台子 Agent:保持运行。
    static func subagentsBackground(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.say("已在后台启动两个子 Agent,你可以继续和我对话。\n\n"),
            .subagent(ScenarioSubagent(
                id: "a_bg1", title: "后台:生成全部接口文档", agentType: "general-purpose", background: true,
                children: [DemoSteps.read("a_bg1_read", "Sources/AtlasCore/Session.swift", c, output: "final class Session { ... }")],
                finish: .running
            )),
            .subagent(ScenarioSubagent(
                id: "a_bg2", title: "后台:巡检依赖漏洞", agentType: "code-reviewer", background: true,
                children: [.text(["正在扫描依赖…"])],
                finish: .running
            )),
        ], used: 33_300)
    }

    // MARK: 状态

    /// 等待与思考:长时间思考,之后保持运行直到被取消。
    static func statesWorking(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            .thought(["这是一个比较复杂的问题,", "需要先检查调用链,", "再评估对性能的影响,", "最后给出方案……"]),
            .delay(600),
            .thought(["继续推理:", "路由层是热路径,", "计数必须无锁或低开销。"]),
            .hold,
        ]
    }

    /// 冻结的工具卡:待处理、进行中、后台子 Agent 停在原地。
    static func statesFrozen(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("下面的卡片会一直停在各自的状态,取消本轮后恢复。\n\n"),
            DemoSteps.read("z_done", "README.md", c, output: "# Atlas"),
            .tool(ScenarioTool(id: "z_pending", title: "编辑 Router.swift", kind: "edit", name: "Edit", input: ["file_path": DemoSteps.path(c, "Sources/AtlasCore/Router.swift")], finish: .pending)),
            .tool(ScenarioTool(id: "z_running", title: "运行 swift test", kind: "execute", name: "Bash", input: ["command": "swift test"], output: "Building for debugging…\n[12/48] Compiling AtlasCore", finish: .running)),
            .tool(ScenarioTool(id: "z_search", title: "搜索 TODO", kind: "search", name: "Grep", input: ["pattern": "TODO"], finish: .running)),
            .subagent(ScenarioSubagent(id: "z_sub", title: "长时间调研", agentType: "Explore", children: [.text(["仍在调研…"])], finish: .running)),
            .hold,
        ]
    }

    /// 提示与用量:三级提示、上下文接近上限、标题与模式更新。
    static func statesNotices(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            .title("演示:提示与用量"),
            .notice(severity: "info", title: "已回退到 Claude Sonnet 5.5", detail: "Claude Fable 5.1 的额度已用尽,已自动改用 Claude Sonnet 5.5,响应质量可能略有差异。"),
            .notice(severity: "warning", title: "上下文已压缩", detail: "旧消息已被摘要,可能丢失细节。\n\n- 保留了最近 20 条消息\n- 丢弃了 3 个超长工具输出"),
            .notice(severity: "error", title: "Hook 拦截了本次操作", detail: "`pre-commit` 返回非零:\n\n```\nlint failed: 3 errors\n```"),
            .text(["这是助手的一段正文,紧随其后是第三方 Agent(如 pi-tps)发来的 TPS 通知行。"]),
            .agentNotify(level: "info", text: "TPS 42.3 tok/s · 输出 512 tokens · 12.1s"),
            .usage(used: 120_000, size: 200_000, cost: 0.31),
            .delay(300),
            .usage(used: 168_000, size: 200_000, cost: 0.52),
            .delay(300),
            .usage(used: 191_000, size: 200_000, cost: 0.68),
            .mode("acceptEdits"),
            DemoSteps.say("提示条与用量环已更新:上下文已用 95%,模式切到「接受编辑」。\n"),
        ]
    }

    /// 各类失败。
    static func statesErrors(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.bash("e_bash", "swift build", output: "error: cannot find 'Metrics' in scope\nRouter.swift:14:13: error: use of unresolved identifier", finish: .failed),
            DemoSteps.edit("e_edit", "Sources/AtlasCore/Router.swift", c, old: "func route", new: "func route2", finish: .failed),
            .tool(ScenarioTool(id: "e_mcp", title: "mcp__github__create_issue", kind: "other", name: "mcp__github__create_issue", input: ["title": "崩溃"], output: "401 Bad credentials", finish: .failed)),
            .subagent(ScenarioSubagent(id: "e_sub", title: "迁移数据库", agentType: "general-purpose", children: [
                DemoSteps.bash("e_sub_cmd", "psql -f migrate.sql", output: "ERROR: relation \"users\" does not exist", finish: .failed),
            ], finish: .failed, result: "迁移失败:users 表不存在。")),
            .notice(severity: "error", title: "本轮出现 4 处失败", detail: "请检查构建错误后重试。"),
        ], used: 44_000)
    }

    /// 慢速长输出。
    static func statesStreaming(_ c: ScenarioContext) -> [ScenarioStep] {
        let paragraph = "路由层是整个请求链路的入口,任何额外的开销都会被放大。因此指标计数必须保持极低的成本:使用无锁的原子计数器,避免在热路径上分配对象,并且把聚合与上报放到后台队列。\n\n"
        let steps: [ScenarioStep] = (1...12).flatMap { index -> [ScenarioStep] in
            [DemoSteps.say("### 第 \(index) 节\n\n" + paragraph, size: 14), .delay(60)]
        }
        return DemoSteps.withUsage([.thought(["写一份较长的设计说明。"])] + steps, used: 88_000)
    }

    // MARK: 角色样式

    /// 会话流角色样式:用户、助手、思维、计划、各级提示、计划文档。
    static func roles(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            .user("帮我给路由层加指标,顺便写个简短的计划。"),
            .thought(["用户要的是指标 + 计划,", "先出计划再动手。"]),
            DemoSteps.say("好的,先给出计划,再逐步实现。\n\n"),
            .plan([
                ScenarioPlanItem("梳理路由结构", priority: "high", status: "completed"),
                ScenarioPlanItem("加入指标计数", priority: "high", status: "in_progress"),
                ScenarioPlanItem("补充单元测试", priority: "medium", status: "pending"),
            ]),
            .notice(severity: "info", title: "这是 info 提示", detail: "普通信息,支持 **Markdown** 与 `代码`。"),
            .notice(severity: "warning", title: "这是 warning 提示", detail: nil),
            .notice(severity: "error", title: "这是 error 提示", detail: "出现了需要注意的错误。"),
            .planDoc("# 实施计划\n\n1. 新增 `Metrics`\n2. 改造 `Router`\n3. 补测试\n"),
            .user("另外别忘了更新文档。"),
            DemoSteps.say("收到,会在最后一步更新 `docs/architecture.md`。\n"),
        ], used: 25_500)
    }

    // MARK: 内置步骤

    /// 内嵌终端。
    static func terminal(_ c: ScenarioContext) -> [ScenarioStep] {
        [DemoSteps.say("我用内嵌终端运行一条命令。\n\n"), .builtin(.terminal), DemoSteps.say("命令已执行完毕。\n")]
    }

    /// 长时间占用。
    static func longRunning(_ c: ScenarioContext) -> [ScenarioStep] {
        [DemoSteps.say("启动一个长命令与一个未完成的子 Agent,看看任务坞。\n\n"), .builtin(.longRunning), DemoSteps.say("两个任务都已结束。\n")]
    }

    // MARK: 全量串联

    /// 依次运行全部自动场景(不含终端、长占用等依赖客户端能力的场景,也不含体量巨大的「性能实验室」场景)。
    static func runAll(_ c: ScenarioContext) -> [ScenarioStep] {
        let skipped: Set<String> = ["all", "terminal", "long-running", "states-streaming", "errors-premature-end"]
        var steps: [ScenarioStep] = []
        for scenario in catalogScenarios where scenario.behavior == .auto && !skipped.contains(scenario.id) && scenario.group != "性能实验室" {
            steps.append(DemoSteps.say("\n\n---\n**场景:\(scenario.title)**(`/demo-\(scenario.id)`)\n\n"))
            steps.append(contentsOf: scenario.build(c))
        }
        return steps
    }
}
