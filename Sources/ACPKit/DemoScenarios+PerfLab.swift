// @author ixxxxoooo
// 演示场景「性能实验室」:专为暴露小会话测不出的性能问题而造的超长/超重会话。
// - `perf-long-2000`:2000 轮长会话(`OMA_TIMELINE_TURNS` 可调),测滚动、加载、跨叶子复制;
// - `perf-long-mixed`:800 轮混合内容(表格/图表/Mermaid/代码/Diff/终端输出轮换);
// - `perf-render-gallery`:渲染画廊(大表格、全部图表、多语言代码、全部 Mermaid、大 Diff)。
// 这些场景由演示历史会话直接引用,点开会话即可,不需要输入命令。

import Foundation

extension DemoScenarios {
    /// 长会话默认轮数。
    static let perfLongTurns = 2_000
    /// 混合内容会话默认轮数。
    static let perfMixedTurns = 800

    /// 读取轮数覆盖(`OMA_TIMELINE_TURNS`),限定在 1…20000。
    /// - Parameters:
    ///   - fallback: 默认轮数
    ///   - environment: 环境变量(测试可注入)
    /// - Returns: 实际轮数
    static func perfTurnCount(fallback: Int, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment["OMA_TIMELINE_TURNS"], let value = Int(raw), value > 0 else { return fallback }
        return min(value, 20_000)
    }

    /// 性能实验室场景(登记到目录)。
    static var perfLabScenarios: [DemoScenario] {
        [
            DemoScenario(id: "perf-long-2000", group: "性能实验室", title: "2000 轮长会话:滚动、加载与跨叶子复制", summary: "2000 轮问答,每 10 轮一张终端卡、每 50 轮一个代码块;用于测会话加载、滚动与跨叶子选择复制(OMA_TIMELINE_TURNS 可调轮数)", build: perfLong),
            DemoScenario(id: "perf-long-mixed", group: "性能实验室", title: "800 轮混合内容:表格、图表、Mermaid、Diff 穿插", summary: "800 轮里按 8 种内容轮换:表格/折线图/Mermaid/代码/Diff/终端输出/待办/长段落", build: perfMixed),
            DemoScenario(id: "perf-render-gallery", group: "性能实验室", title: "渲染画廊:大表格、全部图表与 Mermaid、多语言代码", summary: "60 行宽表格、折线/K 线/柱状图、7 种 Mermaid、12 种语言代码块、220 行大 Diff", build: perfRenderGallery),
        ]
    }

    // MARK: 2000 轮长会话

    /// 构建长会话步骤。
    /// - Parameter c: 场景上下文
    static func perfLong(_ c: ScenarioContext) -> [ScenarioStep] {
        let turns = perfTurnCount(fallback: perfLongTurns)
        var steps: [ScenarioStep] = []
        steps.reserveCapacity(turns * 3)
        for index in 1...turns {
            steps.append(.user("第 \(index) 轮:请继续检查模块 \(index % 40) 的第 \(index % 17 + 1) 个处理函数,并告诉我结论。"))
            steps.append(.text(["第 \(index) 轮结论:", "模块 \(index % 40) 的处理函数行为正常,", "耗时 \(index * 7 % 997) ms,无需修改。\n"]))
            if index % 10 == 0 {
                steps.append(DemoSteps.bash("pl_bash_\(index)", "swift test --filter Module\(index % 40)", description: "运行模块 \(index % 40) 的测试", output: "\u{1B}[32m✔\u{1B}[0m Module\(index % 40) 通过 (\(index % 13 + 3) 项)"))
            }
            if index % 50 == 0 {
                steps.append(DemoSteps.say("参考实现:\n\n```swift\n\(perfSwift(functions: 8, prefix: "r\(index)"))\n```\n"))
            }
        }
        return DemoSteps.withUsage(steps, used: 150_000)
    }

    // MARK: 混合内容

    /// 构建混合内容会话。
    /// - Parameter c: 场景上下文
    static func perfMixed(_ c: ScenarioContext) -> [ScenarioStep] {
        // 混合内容会话最多 800 轮;OMA_TIMELINE_TURNS 只能调小(便于快速冒烟)
        let turns = min(perfTurnCount(fallback: perfMixedTurns), perfMixedTurns)
        var steps: [ScenarioStep] = []
        for index in 1...turns {
            steps.append(.user("第 \(index) 轮:\(perfMixedPrompts[index % 8])"))
            steps.append(contentsOf: perfMixedTurn(index, c))
        }
        return DemoSteps.withUsage(steps, used: 120_000)
    }

    private static let perfMixedPrompts = [
        "汇总一下各模块的指标表", "画一张本周销量折线图", "画出请求处理流程图", "给出参考实现代码",
        "修改路由文件并展示 Diff", "跑一遍构建并展示输出", "列出本轮待办", "详细解释一下设计取舍",
    ]

    /// 某一轮的助手内容(按 `index % 8` 轮换)。
    private static func perfMixedTurn(_ index: Int, _ c: ScenarioContext) -> [ScenarioStep] {
        switch index % 8 {
        case 0:
            let rows = (1...8).map { "| 模块 \($0) | \(($0 + index) * 13 % 97) | \(Double(($0 + index) * 37 % 1000) / 10)% |" }
            return [DemoSteps.say((["| 模块 | 数量 | 占比 |", "| --- | ---: | ---: |"] + rows).joined(separator: "\n") + "\n", size: 60)]
        case 1:
            let values = (0..<6).map { String(($0 + index) * 7 % 40 + 10) }.joined(separator: ",")
            let json = "{\"kind\":\"line\",\"title\":\"第 \(index) 轮趋势\",\"labels\":[\"一\",\"二\",\"三\",\"四\",\"五\",\"六\"],\"series\":[{\"name\":\"销量\",\"values\":[\(values)]}]}"
            return [DemoSteps.say("```chart\n\(json)\n```\n", size: 80)]
        case 2:
            return [DemoSteps.say("```mermaid\nflowchart TD\n  A[请求 \(index)] --> B{校验}\n  B -->|通过| C[处理]\n  B -->|失败| D[拒绝]\n  C --> E([完成])\n```\n", size: 60)]
        case 3:
            return [DemoSteps.say("```swift\n\(perfSwift(functions: 4, prefix: "m\(index)"))\n```\n", size: 80)]
        case 4:
            let old = (1...30).map { "    let v\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
            let new = (1...30).map { $0 % 6 == 0 ? "    let v\($0) = compute(\($0 + index)) // 已调整" : "    let v\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
            return [DemoSteps.edit("pm_edit_\(index)", "Sources/LongChat/Module\(index % 6 + 1).swift", c, old: old, new: new, line: 1)]
        case 5:
            let output = (1...60).map { "[\(String(format: "%03d", $0))] \u{1B}[32mINFO\u{1B}[0m 编译 Module\($0 % 12) (\($0 * 3 % 97) ms)" }.joined(separator: "\n")
            return [DemoSteps.bash("pm_bash_\(index)", "swift build", description: "构建", output: output)]
        case 6:
            return [DemoSteps.say("本轮待办:\n\n- [x] 梳理模块 \(index % 40)\n- [ ] 补充测试 \(index)\n- [ ] 更新文档\n", size: 40)]
        default:
            return [DemoSteps.say(String(repeating: "这是一段较长的解释文字,用于观察长段落折行、选择与滚动的开销。第 \(index) 轮的取舍是:先保证正确性,再逐步优化热点路径。", count: 6) + "\n", size: 96)]
        }
    }

    // MARK: 渲染画廊

    /// 构建渲染画廊步骤。
    /// - Parameter c: 场景上下文
    static func perfRenderGallery(_ c: ScenarioContext) -> [ScenarioStep] {
        let rows = (1...60).map { "| 模块 \($0) | \($0 * 13 % 97) | \(Double($0 * 37 % 1000) / 10)% | 第 \($0) 行说明文字,用来撑出较长的单元格 | 状态\($0 % 4) | 负责人\($0 % 7) | 备注\($0 % 9) |" }
        let table = (["| 模块 | 数量 | 占比 | 说明 | 状态 | 负责人 | 备注 |", "| --- | ---: | ---: | --- | --- | --- | --- |"] + rows).joined(separator: "\n")
        let candles = (0..<60).map { i -> String in
            let base = 1500.0 + Double(i) * 2 + (i % 5 == 0 ? -25 : Double(i % 3) * 8)
            let close = base + (i % 2 == 0 ? 14 : -9)
            return "[\(Int(base)),\(Int(max(base, close)) + 12),\(Int(min(base, close)) - 10),\(Int(close)),\(20_000 + i * 900)]"
        }.joined(separator: ",")
        let labels = (0..<60).map { "\"D\($0 + 1)\"" }.joined(separator: ",")
        let line = "{\"kind\":\"line\",\"title\":\"多序列折线\",\"labels\":[\"1月\",\"2月\",\"3月\",\"4月\",\"5月\",\"6月\"],\"series\":[{\"name\":\"A\",\"values\":[10,20,15,30,25,40]},{\"name\":\"B\",\"values\":[12,18,25,28,31,35]},{\"name\":\"C\",\"values\":[5,9,14,12,20,26]}]}"
        let candle = "{\"kind\":\"candle\",\"title\":\"60 根 K 线\",\"labels\":[\(labels)],\"candles\":[\(candles)],\"ma\":[5,10,20],\"up\":\"red\"}"
        let languages: [(String, String)] = [
            ("swift", "struct A { var x = 1 }"), ("typescript", "export const f = (n: number) => n * 2"), ("python", "def f(n):\n    return n * 2"),
            ("json", "{ \"k\": [1, 2, 3] }"), ("bash", "swift build && swift test"), ("yaml", "name: demo\nitems:\n  - a\n  - b"),
            ("go", "func main() { fmt.Println(\"hi\") }"), ("rust", "fn main() { println!(\"hi\"); }"), ("sql", "SELECT id, name FROM users WHERE id > 10;"),
            ("html", "<div class=\"a\">hi</div>"), ("css", ".a { color: red; }"), ("diff", "- old\n+ new"),
        ]
        let code = languages.map { "```\($0.0)\n\($0.1)\n```\n" }.joined(separator: "\n")
        let old = (1...220).map { "    let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        let new = (1...220).map { $0 % 9 == 0 ? "    let value\($0) = compute(\($0 + 1)) // 已调整" : "    let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        let steps: [ScenarioStep] = [
            .user("把渲染相关的所有元素都输出一遍,方便我对比渲染速度"),
            DemoSteps.say("## 1. 宽表格(60 行 × 7 列)\n\n\(table)\n\n", size: 120),
            DemoSteps.say("## 2. 折线图(三序列)\n\n```chart\n\(line)\n```\n\n", size: 120),
            DemoSteps.say("## 3. K 线(60 根,MA5/10/20 与成交量)\n\n```chart\n\(candle)\n```\n\n", size: 120),
            DemoSteps.say("## 4. Mermaid 全图种\n\n", size: 120),
            .text(mermaidBlocks),
            DemoSteps.say("## 5. 12 种语言代码块\n\n\(code)\n", size: 120),
            DemoSteps.edit("prg_edit", "Sources/Large.swift", c, old: old, new: new, line: 1),
            DemoSteps.say("渲染画廊输出完毕。\n"),
        ]
        return DemoSteps.withUsage(steps, used: 48_000)
    }

    /// 确定性 Swift 代码片段(每个函数 4 行)。
    /// - Parameters:
    ///   - functions: 函数个数
    ///   - prefix: 函数名前缀
    static func perfSwift(functions: Int, prefix: String) -> String {
        (1...max(functions, 1)).map { index in
            "func \(prefix)Handler\(index)(_ request: Request) async throws -> Response {\n    let payload = try await load(\(index), timeout: .seconds(\(index % 30 + 1)))\n    return .ok(payload.map { $0.uppercased() }.joined(separator: \",\"))\n}"
        }.joined(separator: "\n\n")
    }
}
