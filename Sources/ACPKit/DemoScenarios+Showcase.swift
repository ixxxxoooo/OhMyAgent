// @author ixxxxoooo
// 演示场景:全景(一次完整的修 Bug 流程)、用户消息变体(长文折叠/图片/@文件/原样 Markdown)、Markdown 边界样式。

import Foundation

extension DemoScenarios {
    /// 全景:修复路由大小写匹配——用户提问 → 思考 → 浏览 → 待办 → 编辑 → 测试失败 → 再修复 → 测试通过 → 子 Agent 审查 → 总结。
    static func showcaseTour(_ c: ScenarioContext) -> [ScenarioStep] {
        func todos(_ states: [String]) -> JSONValue {
            let names = ["定位路径匹配逻辑", "路径统一为小写并去掉末尾斜杠", "补充大小写回归测试", "跑完整测试并审查改动"]
            return .array(zip(names, states).map { ["content": .string($0), "status": .string($1), "activeForm": .string($0 + "中")] })
        }
        func plan(_ states: [String]) -> ScenarioStep {
            let names = ["定位路径匹配逻辑", "路径统一为小写并去掉末尾斜杠", "补充大小写回归测试", "跑完整测试并审查改动"]
            return .plan(zip(names, states).map { ScenarioPlanItem($0, priority: "high", status: $1) })
        }
        let routerOld = "    func route(_ request: Request) -> Response {\n        return handlers[request.path]?(request) ?? .notFound\n    }\n"
        let routerV1 = "    func route(_ request: Request) -> Response {\n        let key = request.path.lowercased()\n        return handlers[key]?(request) ?? .notFound\n    }\n"
        let routerV2 = "    func route(_ request: Request) -> Response {\n        let key = Router.normalize(request.path)\n        return handlers[key]?(request) ?? .notFound\n    }\n\n    /// 统一为小写并去掉末尾斜杠(根路径除外)。\n    static func normalize(_ path: String) -> String {\n        var key = path.lowercased()\n        while key.count > 1, key.hasSuffix(\"/\") { key.removeLast() }\n        return key\n    }\n"
        let testNew = "    @Test(\"路径匹配忽略大小写与末尾斜杠\")\n    func caseInsensitive() {\n        let router = Router()\n        router.register(\"/api/users\") { _ in .ok }\n        #expect(router.route(.get(\"/API/Users\")) == .ok)\n        #expect(router.route(.get(\"/api/users/\")) == .ok)\n    }\n"
        let failedTest = """
        ◇ Test run started.
        ✘ Test "路径匹配忽略大小写与末尾斜杠" recorded an issue at RouterTests.swift:21:9: Expectation failed: (router.route(.get("/api/users/")) → .notFound) == .ok
        ✘ Test run with 3 tests in 1 suite failed after 0.004 seconds with 1 issue.
        """
        let passedTest = """
        ✔ Test "根路径返回首页" passed after 0.001 seconds.
        ✔ Test "未注册路径返回 404" passed after 0.001 seconds.
        ✔ Test "路径匹配忽略大小写与末尾斜杠" passed after 0.001 seconds.
        ✔ Test run with 3 tests in 1 suite passed after 0.004 seconds.
        """
        return DemoSteps.withUsage([
            .user("线上有用户反馈:访问 /API/Users 会 404,但 /api/users 正常。帮我定位并修好,补上测试,跑一遍确认。"),
            .thought(["先看路由层怎么匹配路径,", "大概率是字典 key 区分大小写。", "改完要补回归测试再跑一遍。"]),
            DemoSteps.say("我先看一下路由的匹配实现和现有测试。\n\n"),
            .tool(ScenarioTool(id: "sc_grep", title: "搜索 route(", kind: "search", name: "Grep", input: ["pattern": "route\\(", "path": DemoSteps.path(c, "Sources")],
                               output: "\(c.cwd)/Sources/AtlasCore/Router.swift:12:    func route(_ request: Request) -> Response {\n\(c.cwd)/Sources/AtlasCore/Session.swift:48:        let response = router.route(request)")),
            DemoSteps.read("sc_read1", "Sources/AtlasCore/Router.swift", c, offset: 1, limit: 30,
                           output: "final class Router {\n    private var handlers: [String: (Request) -> Response] = [:]\n\n    func register(_ path: String, _ handler: @escaping (Request) -> Response) {\n        handlers[path] = handler\n    }\n\n    func route(_ request: Request) -> Response {\n        return handlers[request.path]?(request) ?? .notFound\n    }\n}"),
            DemoSteps.read("sc_read2", "Tests/AtlasCoreTests/RouterTests.swift", c,
                           output: "@Suite struct RouterTests {\n    @Test(\"根路径返回首页\") func root() { ... }\n    @Test(\"未注册路径返回 404\") func notFound() { ... }\n}"),
            DemoSteps.say("确认了:`handlers` 直接用 `request.path` 当 key,**区分大小写**,而且 `/api/users/` 末尾斜杠也会失配。我把待办列出来逐项处理。\n\n"),
            .tool(ScenarioTool(id: "sc_todo1", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["completed", "in_progress", "pending", "pending"])])),
            plan(["completed", "in_progress", "pending", "pending"]),
            DemoSteps.edit("sc_edit1", "Sources/AtlasCore/Router.swift", c, old: routerOld, new: routerV1, line: 12),
            .tool(ScenarioTool(id: "sc_todo2", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["completed", "completed", "in_progress", "pending"])])),
            plan(["completed", "completed", "in_progress", "pending"]),
            DemoSteps.edit("sc_edit_test", "Tests/AtlasCoreTests/RouterTests.swift", c, old: nil, new: testNew, line: 18),
            DemoSteps.bash("sc_test1", "swift test --filter RouterTests", description: "运行路由相关测试", output: failedTest, finish: .failed),
            .thought(["末尾斜杠的用例没过,", "只转小写不够,还要去掉末尾斜杠。"]),
            DemoSteps.say("大小写已经修好,但 `/api/users/`(带末尾斜杠)仍然失配。把归一化抽成函数,一并处理。\n\n"),
            DemoSteps.edit("sc_edit2", "Sources/AtlasCore/Router.swift", c, old: routerV1, new: routerV2, line: 12),
            DemoSteps.bash("sc_test2", "swift test --filter RouterTests", description: "重新运行路由相关测试", output: passedTest),
            .tool(ScenarioTool(id: "sc_todo3", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["completed", "completed", "completed", "in_progress"])])),
            plan(["completed", "completed", "completed", "in_progress"]),
            DemoSteps.say("测试通过。最后让 code-reviewer 看一眼整体改动。\n\n"),
            .subagent(ScenarioSubagent(
                id: "sc_review", title: "审查路由归一化改动", agentType: "code-reviewer",
                children: [
                    DemoSteps.bash("sc_r_diff", "git diff --stat", output: " Sources/AtlasCore/Router.swift          | 11 +++++++++--\n Tests/AtlasCoreTests/RouterTests.swift |  8 ++++++++\n 2 files changed, 17 insertions(+), 2 deletions(-)"),
                    DemoSteps.read("sc_r_read", "Sources/AtlasCore/Router.swift", c, offset: 8, limit: 14, output: "func route(_ request: Request) -> Response { ... }\nstatic func normalize(_ path: String) -> String { ... }"),
                    .text(["归一化逻辑正确。", "注意 `register` 也应使用 `normalize`,", "否则注册时带大写的路径仍然匹配不到。"]),
                ],
                result: "归一化逻辑正确;建议 register 也走 normalize,避免注册时带大写的路径失配。"
            )),
            DemoSteps.edit("sc_edit3", "Sources/AtlasCore/Router.swift", c, old: "        handlers[path] = handler\n", new: "        handlers[Router.normalize(path)] = handler\n", line: 8),
            .tool(ScenarioTool(id: "sc_todo4", title: "更新待办", kind: "other", name: "TodoWrite", input: ["todos": todos(["completed", "completed", "completed", "completed"])])),
            plan(["completed", "completed", "completed", "completed"]),
            DemoSteps.say("""
            ## 已修复路由大小写与末尾斜杠

            **原因**:`Router` 直接用 `request.path` 当字典 key,区分大小写,也不处理末尾斜杠。

            | 文件 | 改动 |
            | --- | --- |
            | `Router.swift` | 新增 `normalize(_:)`,`route` 与 `register` 统一使用 |
            | `RouterTests.swift` | 新增大小写与末尾斜杠的回归测试 |

            - ✅ `swift test --filter RouterTests` 3 项全部通过
            - 🔎 code-reviewer 建议已采纳(`register` 同样归一化)

            需要的话,我可以接着为 `Session` 补一条端到端用例。
            """),
        ], used: 74_600, cost: 0.1384)
    }

    /// 用户消息变体:带图片、@文件文本、长文折叠、纯图片、多图、原样 Markdown。
    static func userVariants(_ c: ScenarioContext) -> [ScenarioStep] {
        let longLines = (1...30).map { "第 \($0) 行:这是一条很长的用户消息,用来演示超过 6 行后自动折叠,并在展开后限高滚动的效果。" }.joined(separator: "\n")
        return DemoSteps.withUsage([
            .user("看下这个页面的报错截图,是不是 @Sources/AtlasCore/Router.swift 里的路径匹配引起的?"),
            .userImage(.errorPage),
            DemoSteps.say("从截图的堆栈看,是 `Router.route` 在未命中时返回了 `.notFound`,与路径匹配有关。\n\n"),
            .user(longLines),
            DemoSteps.say("消息很长,上面的用户消息默认只显示前 6 行,点「展开」可以看全文。\n\n"),
            .userImage(.dashboard),
            DemoSteps.say("只发图片没有文字时,用户消息只显示缩略图。\n\n"),
            .user("对比一下这两张图的差异:"),
            .userImage(.dashboard),
            .userImage(.logo),
            DemoSteps.say("多张图片会横向排成一行,点击任意一张进入灯箱,可缩放、平移、复制和下载。\n\n"),
            .user("**用户消息不渲染 Markdown**:`保持原样`,# 不是标题,- 不是列表\n- 第二行\n> 引用符号也原样显示"),
            DemoSteps.say("用户消息里的 Markdown 语法按原文显示;助手消息则会渲染。\n\n"),
            .user("Please also double check the English wording: \"route\" vs \"router\" in the error messages."),
            DemoSteps.say("英文与中英混排的用户消息同样按原样显示。\n"),
        ], used: 33_800)
    }

    /// Markdown 边界样式:嵌套列表/引用含列表/宽表格/各种围栏/未渲染的语法回退/超长单词/CJK 与表情。
    static func markdownEdge(_ c: ScenarioContext) -> [ScenarioStep] {
        let doc = """
        ## Markdown 边界样式

        #### 四级标题

        ##### 五级标题

        ###### 六级标题

        ### 嵌套列表

        1. 第一步
           - 子项 A
             - 孙项 A1
             - 孙项 A2
           - 子项 B
        2. 第二步
           1. 有序子项一
           2. 有序子项二
        3. 第三步

        - [x] 已完成
          - [ ] 未完成的子任务
          - [x] 已完成的子任务
        - [ ] 待办

        ### 引用与列表

        > 引用里的列表:
        > - 条目一
        > - 条目二
        >
        > 引用里的 `代码` 与 **加粗**。

        ### 宽表格

        | 路由 | 方法 | 处理函数 | 平均耗时 | P95 | P99 | 错误率 | 备注 |
        | --- | --- | --- | --- | --- | --- | --- | --- |
        | /api/users | GET | UsersController.list | 18 ms | 42 ms | 88 ms | 0.2% | 命中缓存后明显下降 |
        | /api/users/:id | GET | UsersController.show | 9 ms | 21 ms | 40 ms | 0.1% | — |
        | /api/metrics/latency | GET | MetricsController.latency | 96 ms | 310 ms | 720 ms | 4.8% | 空数据时返回 500 |

        ### 更多代码围栏

        ```kotlin
        data class Route(val path: String, val handler: (Request) -> Response)
        ```

        ```dockerfile
        FROM swift:6.0-slim
        COPY . /app
        RUN swift build -c release
        ```

        ```toml
        [package]
        name = "atlas"
        version = "1.0.0"
        ```

        ```text
        纯文本围栏不做高亮,保持等宽。
        ```

        ```unknownlang
        未知语言按纯文本显示
        ```

        ### 暂不渲染的语法(当前的回退表现)

        行内公式 $E = mc^2$ 与块公式:

        $$\\int_0^1 x^2 dx = \\frac{1}{3}$$

        图片语法 ![Atlas 看板](https://example.com/atlas.png) 目前只保留替代文字,<b>HTML 标签</b> 按原文显示。

        ### 排版细节

        超长单词不应撑破布局:Supercalifragilisticexpialidocious_Supercalifragilisticexpialidocious_Supercalifragilisticexpialidocious_Supercalifragilisticexpialidocious

        中英文混排 mixed 文本 with emoji 🎉 与全角标点,;。!?「引号」(括号)。

        自动链接 https://github.com/ixxxxoooo/OhMyAgent 与 ~~删除线~~、***粗斜体***。

        ---

        末尾的围栏故意不闭合,用来检查流式时的容错:

        ```swift
        let unfinished = "没有结束的代码块"
        """
        return DemoSteps.withUsage([.thought(["整理一份覆盖边界情况的", "Markdown 示例。"]), DemoSteps.say(doc + "\n", size: 40)], used: 21_000)
    }
}
