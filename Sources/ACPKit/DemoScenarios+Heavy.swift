// @author ixxxxoooo
// 演示场景:重内容压测——超长代码块、2000 行带 ANSI 的终端输出、大 Diff、长表格与长用户消息。
// 用于会话流滚动/挂载/复制的性能基线(`OMA_SCROLL_SWEEP` 可用 `SCENARIO_LONG=heavy-content` 指向它)。

import Foundation

extension DemoScenarios {
    /// 重内容场景:多个回合,每回合都含大体量文字叶子(代码块、输出、Diff、表格)。
    /// - Parameter c: 场景上下文
    /// - Returns: 场景步骤
    static func heavyContent(_ c: ScenarioContext) -> [ScenarioStep] {
        let code = heavySwiftSource(functions: 60)
        let wide = heavySwiftSource(functions: 12).split(separator: "\n").map { String($0) + " // " + String(repeating: "很长的行内注释用于触发横向滚动与折行 ", count: 6) }.joined(separator: "\n")
        let ansi = (1...2000).map { index -> String in
            let level = index % 7 == 0 ? "\u{1B}[31mERROR\u{1B}[0m" : index % 3 == 0 ? "\u{1B}[33mWARN\u{1B}[0m" : "\u{1B}[32mINFO\u{1B}[0m"
            return "[\(String(format: "%04d", index))] \(level) Compiling module Atlas\(index % 40) (\(index * 7 % 997) ms) 构建中…"
        }.joined(separator: "\n")
        let oldText = (1...220).map { "    let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        let newText = (1...220).map { $0 % 9 == 0 ? "    let value\($0) = compute(\($0 + 1)) // 已调整" : "    let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        let table = (["| 模块 | 文件数 | 行数 | 说明 |", "| --- | --- | --- | --- |"]
            + (1...40).map { "| Module\($0) | \($0 * 3) | \($0 * 120) | 第 \($0) 个模块的说明文字 |" }).joined(separator: "\n")
        let longUser = (1...40).map { "第 \($0) 行:这是一条很长的用户消息,用来检查折叠、展开与跨行复制。" }.joined(separator: "\n")

        func turn(_ index: Int) -> [ScenarioStep] {
            [
                .user(index == 1 ? longUser : "第 \(index) 轮:继续输出大体量内容。"),
                .thought(["这一轮要同时展示", "长代码、长输出、大 Diff 与表格。"]),
                DemoSteps.say("## 第 \(index) 轮 · 重内容\n\n先看一段很长的 Swift 代码:\n\n```swift\n\(code)\n```\n\n再看一段带超长行的代码:\n\n```swift\n\(wide)\n```\n\n统计表:\n\n\(table)\n\n结论:以上内容用于压测滚动与选择。\n", size: 160),
                DemoSteps.bash("heavy_bash_\(index)", "swift build -c release", description: "构建(2000 行 ANSI 输出)", output: ansi),
                DemoSteps.edit("heavy_edit_\(index)", "Sources/AtlasCore/Generated\(index).swift", c, old: oldText, new: newText, line: 1),
            ]
        }
        let steps = (1...4).flatMap(turn)
        return DemoSteps.withUsage(steps, used: 64_000)
    }

    /// 生成指定函数个数的 Swift 源码文本(确定性,无随机)。
    /// - Parameter functions: 函数个数
    /// - Returns: 源码
    private static func heavySwiftSource(functions: Int) -> String {
        (1...max(functions, 1)).map { index in
            """
            /// 第 \(index) 个函数:演示用的确定性代码。
            func handler\(index)(_ request: Request, retries: Int = \(index % 5)) async throws -> Response {
                guard request.path.hasPrefix("/api/v\(index % 3 + 1)") else { return .notFound }
                let payload = try await load(\(index), timeout: .seconds(\(index % 30 + 1)))
                return .ok(payload.map { $0.uppercased() }.joined(separator: ","))
            }
            """
        }.joined(separator: "\n\n")
    }

    /// 重内容演示场景(登记到目录)。
    static var heavyScenarios: [DemoScenario] {
        [
            DemoScenario(id: "heavy-content", group: "会话流样式", title: "重内容压测:长代码、2000 行输出与大 Diff", summary: "四个回合,每回合含 60 个函数的长代码块、超长行代码、40 行表格、2000 行 ANSI 构建输出与 220 行 Diff,用于滚动与选择性能基线", build: heavyContent),
        ]
    }
}
