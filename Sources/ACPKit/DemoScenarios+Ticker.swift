// @author ixxxxoooo
// 演示场景:精简模式下折叠分组的「最新一步」行(流光、翻转挤压、规划下一步占位)。
// 12 个连续的读取/搜索/命令折进同一个分组,每步停留片刻以便看清滚动;中途穿插思考形成空窗。

import Foundation

extension DemoScenarios {
    /// 「最新一步」行场景。
    static let tickerScenarios: [DemoScenario] = [
        DemoScenario(id: "compact-ticker", group: "工具卡", title: "精简模式:折叠分组的最新一步", summary: "12 个连续命令折进一个分组:收起时标题下方只显示最新一步并带流光,新步骤自下翻入、旧步骤被挤出;步骤间的空窗显示「规划下一步…」(需把工具密度设为精简)", build: compactTicker),
    ]

    /// 带停留时间的只读步骤(停留期间保持「进行中」,让流光与翻转可见)。
    private static func tickerStep(_ id: String, kind: String, name: String, title: String, input: JSONValue, output: String, hold: Int = 1100) -> ScenarioStep {
        .tool(ScenarioTool(id: id, title: title, kind: kind, name: name, input: input, output: output, holdMillis: hold))
    }

    /// 12 个步骤 + 两次空窗 + 收尾编辑。
    static func compactTicker(_ c: ScenarioContext) -> [ScenarioStep] {
        func read(_ n: Int, _ file: String) -> ScenarioStep {
            tickerStep("tk_\(n)", kind: "read", name: "Read", title: "读取 " + file,
                       input: .object(["file_path": DemoSteps.path(c, "Sources/AtlasCore/" + file)]), output: "// \(file)\n// …")
        }
        func grep(_ n: Int, _ pattern: String) -> ScenarioStep {
            tickerStep("tk_\(n)", kind: "search", name: "Grep", title: "搜索 " + pattern,
                       input: .object(["pattern": .string(pattern), "path": DemoSteps.path(c, "Sources")]), output: "Sources/AtlasCore/Router.swift:42: \(pattern)")
        }
        func shell(_ n: Int, _ command: String) -> ScenarioStep {
            tickerStep("tk_\(n)", kind: "execute", name: "Bash", title: "运行 " + command,
                       input: .object(["command": .string(command)]), output: "ok")
        }
        return DemoSteps.withUsage([
            DemoSteps.say("我来系统地摸一遍路由层,会连续读很多文件、跑一些命令。\n\n"),
            read(1, "Router.swift"),
            grep(2, "func route"),
            read(3, "Session.swift"),
            shell(4, "ls Sources/AtlasCore"),
            grep(5, "metrics.count"),
            read(6, "Cache.swift"),
            .thought(["第一轮看完了,", "先梳理一下调用关系,", "再决定下一批要看哪些文件。"]),
            .delay(1200),
            read(7, "Metrics.swift"),
            shell(8, "git log --oneline -5 -- Sources/AtlasCore/Router.swift"),
            grep(9, "handlers\\["),
            read(10, "Middleware.swift"),
            shell(11, "wc -l Sources/AtlasCore/*.swift"),
            read(12, "Errors.swift"),
            .thought(["全部读完了,", "现在汇总结论,", "准备动手修改。"]),
            .delay(2000),
            DemoSteps.say("读完了。路由未命中时没有上报指标,我在 `route` 里补一行计数。\n\n"),
            DemoSteps.edit("tk_edit", "Sources/AtlasCore/Router.swift", c, old: "        return .notFound\n", new: "        metrics.count(\"router.miss\")\n        return .notFound\n", line: 42),
            DemoSteps.say("已补上 `router.miss` 计数。\n"),
        ], used: 38_000)
    }
}
