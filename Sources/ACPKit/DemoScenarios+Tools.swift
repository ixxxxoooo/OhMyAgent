// @author ixxxxoooo
// 演示场景:各类工具卡(文件、终端、联网/MCP、待办/计划)、权限变体、计划批准、提问向导、Mermaid、Markdown。
// 路径以工作区目录为根,与 DemoKit 生成的 `atlas-web` 演示项目的目录结构一致。

import Foundation

/// 场景构建辅助。
enum DemoSteps {
    /// 把长文本切成小块,模拟流式输出。
    /// - Parameters:
    ///   - text: 文本
    ///   - size: 每块字符数
    static func chunks(_ text: String, size: Int = 28) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        return stride(from: 0, to: characters.count, by: size).map { String(characters[$0..<min($0 + size, characters.count)]) }
    }

    /// 流式助手文本。
    static func say(_ text: String, size: Int = 28) -> ScenarioStep { .text(chunks(text, size: size)) }

    /// 工作区内的绝对路径。
    static func path(_ ctx: ScenarioContext, _ relative: String) -> JSONValue { .string(ctx.cwd + "/" + relative) }

    /// 读取文件工具。
    static func read(_ id: String, _ relative: String, _ ctx: ScenarioContext, offset: Int? = nil, limit: Int? = nil, output: String, finish: ScenarioFinish = .completed) -> ScenarioStep {
        var input: [String: JSONValue] = ["file_path": path(ctx, relative)]
        if let offset { input["offset"] = .int(offset) }
        if let limit { input["limit"] = .int(limit) }
        return .tool(ScenarioTool(
            id: id, title: "读取 " + (relative as NSString).lastPathComponent, kind: "read", name: "Read",
            input: .object(input), output: output, finish: finish,
            locations: [["path": path(ctx, relative), "line": .int(offset ?? 1)]]
        ))
    }

    /// 终端命令工具。
    static func bash(_ id: String, _ command: String, description: String? = nil, output: String?, finish: ScenarioFinish = .completed, background: Bool = false) -> ScenarioStep {
        var input: [String: JSONValue] = ["command": .string(command)]
        if let description { input["description"] = .string(description) }
        if background { input["run_in_background"] = true }
        let first = command.split(separator: "\n").first.map(String.init) ?? command
        return .tool(ScenarioTool(id: id, title: "运行 " + first, kind: "execute", name: "Bash", input: .object(input), output: output, finish: finish))
    }

    /// 带 Diff 的编辑工具。
    static func edit(_ id: String, _ relative: String, _ ctx: ScenarioContext, name: String = "Edit", old: String?, new: String, line: Int = 1, finish: ScenarioFinish = .completed) -> ScenarioStep {
        .tool(ScenarioTool(
            id: id, title: (old == nil ? "写入 " : "编辑 ") + (relative as NSString).lastPathComponent, kind: "edit", name: name,
            input: ["file_path": path(ctx, relative)], extra: [diff(path(ctx, relative), old: old, new: new)], finish: finish,
            locations: [["path": path(ctx, relative), "line": .int(line)]]
        ))
    }

    /// Diff 内容块。
    static func diff(_ path: JSONValue, old: String?, new: String) -> JSONValue {
        var block: [String: JSONValue] = ["type": "diff", "path": path, "newText": .string(new)]
        if let old { block["oldText"] = .string(old) }
        return .object(block)
    }

    /// 在场景末尾补一次用量更新(让输入栏的上下文环有数据)。
    static func withUsage(_ steps: [ScenarioStep], used: Int, cost: Double = 0.0421) -> [ScenarioStep] {
        steps + [.usage(used: used, size: 200_000, cost: cost)]
    }
}

// MARK: - 工具卡场景

extension DemoScenarios {
    /// 文件类工具:查找、读取(含长输出)、搜索、新建、编辑、多处编辑、Notebook、删除、移动。
    static func toolsFiles(_ c: ScenarioContext) -> [ScenarioStep] {
        let routerOld = "    func route(_ request: Request) -> Response {\n        return handlers[request.path]?(request) ?? .notFound\n    }\n"
        let routerNew = "    func route(_ request: Request) -> Response {\n        guard let handler = handlers[request.path] else {\n            metrics.count(\"router.miss\")\n            return .notFound\n        }\n        return handler(request)\n    }\n"
        let longFile = (1...64).map { "// \($0): 缓存条目 entry\($0) —— 演示超长输出的折叠与滚动" }.joined(separator: "\n")
        return DemoSteps.withUsage([
            .thought(["需要先摸清路由层的结构,", "再决定在哪里加指标。"]),
            DemoSteps.say("我先查看项目里的 Swift 源文件和路由实现。\n\n"),
            .tool(ScenarioTool(id: "f_glob", title: "查找 Sources/**/*.swift", kind: "search", name: "Glob", input: ["pattern": "Sources/**/*.swift"],
                               output: ["Sources/AtlasCore/Router.swift", "Sources/AtlasCore/Session.swift", "Sources/AtlasCore/Cache.swift", "Sources/AtlasCore/Metrics.swift"].map { c.cwd + "/" + $0 }.joined(separator: "\n"))),
            DemoSteps.read("f_read1", "Sources/AtlasCore/Router.swift", c, offset: 1, limit: 40,
                           output: "import Foundation\n\n/// 请求路由:把路径映射到处理函数。\nfinal class Router {\n    private var handlers: [String: (Request) -> Response] = [:]\n\n    func register(_ path: String, _ handler: @escaping (Request) -> Response) {\n        handlers[path] = handler\n    }\n\n    func route(_ request: Request) -> Response {\n        return handlers[request.path]?(request) ?? .notFound\n    }\n}"),
            DemoSteps.read("f_read2", "Sources/AtlasCore/Cache.swift", c, output: longFile),
            .tool(ScenarioTool(id: "f_grep", title: "搜索 route(", kind: "search", name: "Grep", input: ["pattern": "route\\(", "path": DemoSteps.path(c, "Sources"), "glob": "*.swift"],
                               output: [
                                   "\(c.cwd)/Sources/AtlasCore/Router.swift:12:    func route(_ request: Request) -> Response {",
                                   "\(c.cwd)/Sources/AtlasCore/Session.swift:48:        let response = router.route(request)",
                                   "\(c.cwd)/Tests/AtlasCoreTests/RouterTests.swift:9:        #expect(router.route(.get(\"/\")) == .ok)",
                                   "\(c.cwd)/Tests/AtlasCoreTests/RouterTests.swift:15:        #expect(router.route(.get(\"/nope\")) == .notFound)",
                               ].joined(separator: "\n"))),
            DemoSteps.read("f_read3", "docs/architecture.md", c, output: "# 架构\n\n请求先进入 Router,再交给 Session 处理。"),
            DemoSteps.say("找到了:`route(_:)` 在未命中时直接返回 `.notFound`,没有任何计数。下面新增指标文件并改造路由。\n\n"),
            DemoSteps.edit("f_write", "Sources/AtlasCore/Metrics.swift", c, name: "Write", old: nil,
                           new: "import Foundation\n\n/// 轻量计数器。\nfinal class Metrics: @unchecked Sendable {\n    private var counters: [String: Int] = [:]\n    private let lock = NSLock()\n\n    func count(_ name: String) {\n        lock.lock(); defer { lock.unlock() }\n        counters[name, default: 0] += 1\n    }\n}\n"),
            DemoSteps.edit("f_edit", "Sources/AtlasCore/Router.swift", c, old: routerOld, new: routerNew, line: 12),
            .tool(ScenarioTool(
                id: "f_multi", title: "编辑 Session.swift(2 处)", kind: "edit", name: "MultiEdit", input: ["file_path": DemoSteps.path(c, "Sources/AtlasCore/Session.swift")],
                extra: [
                    DemoSteps.diff(DemoSteps.path(c, "Sources/AtlasCore/Session.swift"), old: "    let router = Router()\n", new: "    let router = Router()\n    let metrics = Metrics()\n"),
                    DemoSteps.diff(DemoSteps.path(c, "Sources/AtlasCore/Session.swift"), old: "        let response = router.route(request)\n", new: "        metrics.count(\"session.request\")\n        let response = router.route(request)\n"),
                ],
                locations: [["path": DemoSteps.path(c, "Sources/AtlasCore/Session.swift"), "line": 48]]
            )),
            .tool(ScenarioTool(
                id: "f_nb", title: "编辑 analysis.ipynb", kind: "edit", name: "NotebookEdit",
                input: ["notebook_path": DemoSteps.path(c, "notebooks/analysis.ipynb"), "cell_id": "c3", "edit_mode": "replace"],
                extra: [DemoSteps.diff(DemoSteps.path(c, "notebooks/analysis.ipynb"), old: "df.describe()", new: "df.describe(percentiles: [0.5, 0.95])")]
            )),
            .tool(ScenarioTool(id: "f_del", title: "删除 Legacy.swift", kind: "delete", name: "Delete", input: ["file_path": DemoSteps.path(c, "Sources/AtlasCore/Legacy.swift")],
                               locations: [["path": DemoSteps.path(c, "Sources/AtlasCore/Legacy.swift")]])),
            .tool(ScenarioTool(id: "f_mv", title: "移动 Util.swift → Support/Util.swift", kind: "move", name: "Move",
                               input: ["path": DemoSteps.path(c, "Sources/AtlasCore/Util.swift"), "destination": DemoSteps.path(c, "Sources/AtlasCore/Support/Util.swift")])),
            DemoSteps.say("改动完成:\n\n- 新增 `Metrics`\n- `Router` 记录未命中\n- `Session` 记录请求量\n- 清理了 `Legacy.swift`\n"),
        ], used: 61_500)
    }

    /// 终端类工具:带 ANSI 颜色的输出、超长输出、失败、多行命令、后台命令。
    static func toolsShell(_ c: ScenarioContext) -> [ScenarioStep] {
        let longLog = (1...90).map { String(format: "[%02d:%02d:%02d] worker-%d  processed batch %03d  ok", $0 / 3600, ($0 / 60) % 60, $0 % 60, $0 % 4, $0) }.joined(separator: "\n")
        return DemoSteps.withUsage([
            DemoSteps.say("先构建,再跑测试,最后启动开发服务器。\n\n"),
            DemoSteps.bash("s_build", "swift build", description: "构建工程",
                           output: "\u{1B}[1mCompiling\u{1B}[0m AtlasCore Router.swift\n\u{1B}[1mCompiling\u{1B}[0m AtlasCore Session.swift\n\u{1B}[32mBuild complete!\u{1B}[0m (4.21s)"),
            DemoSteps.bash("s_test", "swift test --filter RouterTests", description: "运行路由测试",
                           output: "\u{1B}[32m✔\u{1B}[0m Test \"命中\" passed after 0.001 seconds.\n\u{1B}[32m✔\u{1B}[0m Test \"未命中\" passed after 0.001 seconds.\n\u{1B}[31m✘\u{1B}[0m Test \"通配\" failed: expected .ok, got .notFound\n\u{1B}[1;33mwarning:\u{1B}[0m 1 test failed\nexit 1",
                           finish: .failed),
            DemoSteps.bash("s_log", "tail -n 90 logs/worker.log", description: "查看 worker 日志(超长输出)", output: longLog),
            DemoSteps.bash("s_multi", "set -e\ncd web\nnpm ci --silent\nnpm run lint -- --max-warnings 0", description: "安装依赖并检查",
                           output: "added 312 packages in 6s\n\n> web@1.0.0 lint\n> eslint src --max-warnings 0\n"),
            DemoSteps.bash("s_git", "git log --oneline -n 5", output: "e2a84d4 perf: 标签内容 LRU 保活\n4c40961 feat: 去掉窗口工具栏\na94a05e feat: 等待文案\n9ea0c60 feat: 去掉窗口标题行\n55432e3 docs: 更新开发进度"),
            DemoSteps.bash("s_fail", "cat missing.txt", output: "cat: missing.txt: No such file or directory", finish: .failed),
            DemoSteps.bash("s_bg", "npm run dev", description: "后台启动开发服务器", output: "  VITE v5.0.0  ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/", finish: .running, background: true),
            DemoSteps.say("开发服务器已在后台运行,可在任务坞里查看。\n"),
        ], used: 74_200)
    }

    /// 联网与 MCP 工具。
    static func toolsWebMcp(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.say("我来查一下官方文档,再用 GitHub 与浏览器工具核对。\n\n"),
            .tool(ScenarioTool(id: "w_search", title: "联网搜索 swift 6 strict concurrency", kind: "fetch", name: "WebSearch",
                               input: ["query": "swift 6 strict concurrency migration"],
                               output: "1. Migrating to Swift 6 — swift.org\n2. Data-race safety — Apple Developer\n3. Adopting strict concurrency in Swift 5 — WWDC")),
            .tool(ScenarioTool(id: "w_fetch", title: "获取 swift.org/migration", kind: "fetch", name: "WebFetch",
                               input: ["url": "https://www.swift.org/migration/documentation/migrationguide/", "prompt": "总结迁移步骤"],
                               output: "迁移分三步:\n1. 开启 `-strict-concurrency=complete`\n2. 逐个模块修复 Sendable 诊断\n3. 切换到 Swift 6 语言模式")),
            .tool(ScenarioTool(id: "w_gh", title: "mcp__github__list_pull_requests", kind: "other", name: "mcp__github__list_pull_requests",
                               input: ["owner": "ixxxxoooo", "repo": "atlas-web", "state": "open"],
                               output: "[{\"number\": 128, \"title\": \"feat: 指标计数\", \"user\": \"ixxxxoooo\"}, {\"number\": 131, \"title\": \"fix: 路由大小写\", \"user\": \"mei\"}]")),
            .tool(ScenarioTool(id: "w_pw", title: "mcp__playwright__browser_navigate", kind: "other", name: "mcp__playwright__browser_navigate",
                               input: ["url": "http://localhost:5173"], output: "Page title: Atlas")),
            .tool(ScenarioTool(id: "w_fs", title: "mcp__filesystem__read_file", kind: "other", name: "mcp__filesystem__read_file",
                               input: ["path": "/etc/secret"], output: "Error: access denied outside allowed directories", finish: .failed)),
            DemoSteps.say("已确认:两个未合并的 PR 都与路由有关,页面本地可正常打开。\n"),
        ], used: 52_800)
    }

    /// 待办、思考、模式切换。
    static func toolsPlanTodo(_ c: ScenarioContext) -> [ScenarioStep] {
        func todos(_ states: [String]) -> JSONValue {
            let names = ["梳理路由结构", "加入指标计数", "补充单元测试", "更新文档"]
            return .array(zip(names, states).map { ["content": .string($0), "status": .string($1), "activeForm": .string($0 + "中")] })
        }
        let names = ["梳理路由结构", "加入指标计数", "补充单元测试", "更新文档"]
        func plan(_ states: [String]) -> ScenarioStep {
            .plan(zip(names, states).map { ScenarioPlanItem($0, priority: "high", status: $1) })
        }
        return DemoSteps.withUsage([
            .thought(["这个任务有四步,", "先列出待办再逐项推进。"]),
            .tool(ScenarioTool(id: "p_think", title: "分析方案", kind: "think", name: "Think", input: ["thought": "指标应当在 Router 层统计,避免侵入业务。"], output: "决定在 Router 层统计。")),
            .tool(ScenarioTool(id: "p_todo", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["in_progress", "pending", "pending", "pending"])])),
            plan(["in_progress", "pending", "pending", "pending"]),
            .delay(300),
            .tool(ScenarioTool(id: "p_todo2", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["completed", "in_progress", "pending", "pending"])])),
            plan(["completed", "in_progress", "pending", "pending"]),
            .delay(300),
            .tool(ScenarioTool(id: "p_mode", title: "切换到 acceptEdits 模式", kind: "switch_mode", name: "SwitchMode", input: ["mode": "acceptEdits"])),
            .mode("acceptEdits"),
            plan(["completed", "completed", "in_progress", "pending"]),
            .delay(300),
            plan(["completed", "completed", "completed", "completed"]),
            DemoSteps.say("四项待办全部完成。\n"),
        ], used: 38_900)
    }

    /// 权限变体:Diff 预览、Bash 命令(含「始终允许」)、新建文件。任一被拒绝即结束本轮。
    static func permissions(_ c: ScenarioContext) -> [ScenarioStep] {
        DemoSteps.withUsage([
            DemoSteps.say("接下来会连续请求三次权限,可分别尝试允许/始终允许/拒绝。\n\n"),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pm_edit", title: "修改 Router.swift", kind: "edit", name: "Edit", input: ["file_path": DemoSteps.path(c, "Sources/AtlasCore/Router.swift")],
                extra: [DemoSteps.diff(DemoSteps.path(c, "Sources/AtlasCore/Router.swift"), old: "return handlers[request.path]?(request) ?? .notFound", new: "return handlers[request.path.lowercased()]?(request) ?? .notFound")],
                locations: [["path": DemoSteps.path(c, "Sources/AtlasCore/Router.swift"), "line": 12]]))),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pm_bash", title: "rm -rf .build && swift build", kind: "execute", name: "Bash",
                input: ["command": "rm -rf .build && swift build", "description": "清理并重新构建"], output: "Build complete!"), options: .withAlways, rejectedText: "好的,我不会清理构建目录。")),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pm_write", title: "写入 .env.example", kind: "edit", name: "Write", input: ["file_path": DemoSteps.path(c, ".env.example")],
                extra: [DemoSteps.diff(DemoSteps.path(c, ".env.example"), old: nil, new: "ATLAS_PORT=8080\nATLAS_LOG=info\n")]), options: .withAlways)),
            DemoSteps.say("三项操作均已获批并完成。\n"),
        ], used: 29_300)
    }

    /// 计划批准:ExitPlanMode + 计划文档。
    static func planApproval(_ c: ScenarioContext) -> [ScenarioStep] {
        let plan = "# 为路由层加入指标\n\n## 目标\n统计路由命中与未命中次数,并暴露给监控。\n\n## 步骤\n1. 新增 `Metrics`(线程安全计数器)\n2. `Router.route` 在未命中时计数\n3. `Session` 统计请求总量\n4. 为 `RouterTests` 补充计数断言\n\n## 风险\n- 计数器使用锁,高并发下需观察开销\n\n```swift\nmetrics.count(\"router.miss\")\n```\n"
        let names = ["新增 `Metrics`(线程安全计数器)", "`Router.route` 在未命中时计数", "`Session` 统计请求总量", "为 `RouterTests` 补充计数断言"]
        func todos(_ states: [String]) -> ScenarioStep { .plan(zip(names, states).map { ScenarioPlanItem($0, priority: "high", status: $1) }) }
        return DemoSteps.withUsage([
            .mode("plan"),
            .thought(["先梳理完再提交计划,", "不直接改代码。"]),
            DemoSteps.say("我已经梳理完毕,下面提交实施计划,请审阅。\n\n"),
            .permission(ScenarioPermission(tool: ScenarioTool(
                id: "pa_plan", title: "提交计划", kind: "switch_mode", name: "ExitPlanMode", input: ["plan": .string(plan)]),
                options: .plan, rejectedText: "好的,我继续完善计划。")),
            .mode("acceptEdits"),
            DemoSteps.say("计划已批准,切到自动接受编辑,开始按计划逐项实施。\n\n"),
            todos(["in_progress", "pending", "pending", "pending"]),
            DemoSteps.edit("pa_e1", "Sources/AtlasCore/Metrics.swift", c, name: "Write", old: nil, new: "final class Metrics: @unchecked Sendable {\n    func count(_ name: String) { /* ... */ }\n}\n"),
            todos(["completed", "in_progress", "pending", "pending"]),
            DemoSteps.edit("pa_e2", "Sources/AtlasCore/Router.swift", c, old: "return handlers[request.path]?(request) ?? .notFound", new: "metrics.count(\"router.miss\")\n        return handlers[request.path]?(request) ?? .notFound", line: 12),
            todos(["completed", "completed", "in_progress", "pending"]),
            DemoSteps.say("前两项已完成,计划卡里的 TODO 会随进度同步。\n"),
        ], used: 22_000)
    }

    /// 提问向导(AskUserQuestion)。
    static func ask(_ c: ScenarioContext) -> [ScenarioStep] {
        [.thought(["有两种可行方案,", "需要用户拍板。"]), .builtin(.ask)]
    }

    /// 本轮改动汇总:真实修改 `oma-demo.txt` 并请求权限。
    static func changes(_ c: ScenarioContext) -> [ScenarioStep] {
        [DemoSteps.say("我会真实修改工作区里的 `oma-demo.txt`,完成后可在「改动」里查看与回退。\n\n"), .builtin(.edit), DemoSteps.say("修改完成。\n")]
    }

    /// Mermaid 全部图种。
    static func mermaid(_ c: ScenarioContext) -> [ScenarioStep] {
        [DemoSteps.say("下面是各种图的渲染效果:\n\n"), .text(mermaidBlocks), DemoSteps.say("最后一个类型暂不支持,会回退为代码块。\n")]
    }

    /// Markdown 全元素与多语言代码高亮。
    static func markdown(_ c: ScenarioContext) -> [ScenarioStep] {
        let doc = """
        # 一级标题

        ## 二级标题

        ### 三级标题

        正文支持 **加粗**、*斜体*、~~删除线~~、`行内代码` 与 [链接](https://example.com)。

        > 引用块:演示在会话流里的缩进与配色。
        > 第二行引用。

        - 无序列表项一
        - 无序列表项二
          - 嵌套子项
        - [x] 已完成的任务
        - [ ] 未完成的任务

        1. 有序列表一
        2. 有序列表二

        | 模块 | 职责 | 状态 |
        | --- | --- | --- |
        | ACPKit | 协议 | 稳定 |
        | ChatKit | 会话 | 迭代中 |

        ```swift
        struct Router {
            var handlers: [String: (Request) -> Response] = [:]
        }
        ```

        ```typescript
        export async function load(id: string): Promise<User> {
          return (await fetch(`/api/users/${id}`)).json();
        }
        ```

        ```python
        def fib(n: int) -> int:
            return n if n < 2 else fib(n - 1) + fib(n - 2)
        ```

        ```json
        { "name": "atlas", "version": "1.0.0", "private": true }
        ```

        ```bash
        swift build && swift test
        ```

        ```diff
        - let debug = false
        + let debug = true
        ```

        ---

        结尾段落。
        """
        return DemoSteps.withUsage([.thought(["整理一份覆盖所有", "Markdown 元素的示例。"]), DemoSteps.say(doc + "\n", size: 36)], used: 18_000)
    }
}
