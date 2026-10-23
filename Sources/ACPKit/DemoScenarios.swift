// @author ixxxxoooo
// 演示场景目录:每个场景是一组声明式步骤,由 `ScriptedAgent` 的场景引擎执行。
// 触发方式:提示词里写 `#demo-<场景名>`(演示模式在输入框以 `/demo-<场景名>` 斜杠命令暴露);
// 旧关键字 `#sub` / `#sub2` / `#showcase` / `#mermaid` 继续有效(既有测试依赖)。

import Foundation

/// 一个演示场景。
public struct DemoScenario: Sendable, Identifiable {
    /// 场景名(同时是 `#demo-<id>` 的后缀),只含小写字母、数字与连字符
    public let id: String
    /// 分组,用于命令面板归类
    public let group: String
    /// 中文标题
    public let title: String
    /// 一句话说明
    public let summary: String
    /// 运行方式
    public let behavior: Behavior
    /// 构建步骤(可读取工作区路径等上下文)
    public let build: @Sendable (ScenarioContext) -> [ScenarioStep]

    /// 场景的运行方式。
    public enum Behavior: Sendable, Equatable {
        /// 自动跑完
        case auto
        /// 中途需要用户操作(批准权限、回答问题)
        case interactive
        /// 冻结:最后停在某个状态,直到用户取消
        case frozen
        /// 自动跑完,但回合以非 `end_turn` 的停止原因(拒绝、输出上限等)或 JSON-RPC 错误收尾,用来展示各类结束提示
        case failing
    }

    public init(id: String, group: String, title: String, summary: String, behavior: Behavior = .auto, build: @escaping @Sendable (ScenarioContext) -> [ScenarioStep]) {
        self.id = id
        self.group = group
        self.title = title
        self.summary = summary
        self.behavior = behavior
        self.build = build
    }

    /// 斜杠命令名(不含 `/`)。
    public var commandName: String { "demo-" + id }
}

/// 提示词命中的场景。
public struct DemoScenarioMatch: Sendable {
    public var scenario: DemoScenario
    /// 是否由 `#demo-` 触发(区别于旧关键字)
    public var isDemo: Bool
}

/// 场景目录与匹配。
public enum DemoScenarios {
    /// 全部演示场景(不含旧关键字场景)。
    public static var all: [DemoScenario] { catalog }

    /// 按名称查找演示场景。
    /// - Parameter name: 场景名(不含 `demo-` 前缀)
    public static func scenario(named name: String) -> DemoScenario? {
        catalog.first { $0.id == name }
    }

    /// 从提示词中找出要运行的场景:先旧关键字(保持原有顺序),再 `#demo-<名>`(按出现顺序)。
    /// - Parameter prompt: 提示词文本
    /// - Returns: 命中的场景列表
    public static func matching(prompt: String) -> [DemoScenarioMatch] {
        var result: [DemoScenarioMatch] = []
        if prompt.contains("#sub") {
            result.append(DemoScenarioMatch(scenario: prompt.contains("#sub2") ? legacySubagent2 : legacySubagent, isDemo: false))
        }
        if prompt.contains("#showcase") { result.append(DemoScenarioMatch(scenario: legacyShowcase, isDemo: false)) }
        if prompt.contains("#mermaid") { result.append(DemoScenarioMatch(scenario: legacyMermaid, isDemo: false)) }
        // `#demo-<名>`(提示词关键字)与 `/demo-<名>`(斜杠命令)等价
        for token in prompt.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix("#demo-") || token.hasPrefix("/demo-") {
            let name = String(token.dropFirst("#demo-".count)).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
            if let scenario = scenario(named: name) { result.append(DemoScenarioMatch(scenario: scenario, isDemo: true)) }
        }
        return result
    }

    /// 下发给客户端的斜杠命令描述(`available_commands_update`):每个场景一条 `/demo-<名>`。
    public static var commandDescriptors: [JSONValue] {
        catalog.map { scenario in
            ["name": .string(scenario.commandName), "description": .string("演示 · \(scenario.group) · \(scenario.title):\(scenario.summary)"), "input": JSONValue.null]
        }
    }

    // MARK: 旧关键字场景(行为与重构前保持一致)

    /// `#sub`:单层子 Agent。
    static let legacySubagent = DemoScenario(id: "legacy-sub", group: "legacy", title: "子 Agent", summary: "旧关键字 #sub") { ctx in
        [.subagent(subagentWithRead(nested: false, ctx: ctx))]
    }

    /// `#sub2`:两层子 Agent。
    static let legacySubagent2 = DemoScenario(id: "legacy-sub2", group: "legacy", title: "嵌套子 Agent", summary: "旧关键字 #sub2") { ctx in
        [.subagent(subagentWithRead(nested: true, ctx: ctx))]
    }

    private static func subagentWithRead(nested: Bool, ctx: ScenarioContext) -> ScenarioSubagent {
        var children: [ScenarioStep] = [
            .tool(ScenarioTool(id: "sub_read", title: "读取 README.md", kind: "read", name: "Read", input: ["file_path": .string(ctx.cwd + "/README.md")])),
            .text(["子 Agent 的中间结论。"]),
        ]
        if nested {
            children.append(.subagent(ScenarioSubagent(id: "sub_2", title: "子任务:分析依赖", children: [
                .tool(ScenarioTool(id: "sub2_grep", title: "搜索 import", kind: "search", name: "Grep", input: ["pattern": "import"])),
                .text(["第二层子 Agent 的结论。"]),
            ])))
        }
        return ScenarioSubagent(id: "sub_1", title: "子任务:调研代码", children: children)
    }

    /// `#showcase`:覆盖读/搜/写/改/终端/MCP/联网/失败的一组工具。
    static let legacyShowcase = DemoScenario(id: "legacy-showcase", group: "legacy", title: "工具展示", summary: "旧关键字 #showcase") { ctx in
        let cwd = ctx.cwd
        let main = cwd + "/Sources/App/main.swift"
        return [
            .tool(ScenarioTool(id: "t_read1", title: "读取 main.swift", kind: "read", name: "Read",
                               input: ["file_path": .string(main), "offset": 10, "limit": 50],
                               output: "let app = App()\napp.run()", locations: [["path": .string(main), "line": 10]])),
            .tool(ScenarioTool(id: "t_read2", title: "读取 Package.swift", kind: "read", name: "Read",
                               input: ["file_path": .string(cwd + "/Package.swift")], output: "// swift-tools-version: 6.4")),
            .tool(ScenarioTool(id: "t_grep", title: "搜索 TODO", kind: "search", name: "Grep",
                               input: ["pattern": "TODO", "path": .string(cwd + "/Sources")],
                               output: "\(main):12:    // TODO: 处理错误\n\(cwd)/Sources/App/Util.swift:40:    // TODO: 缓存\n\(cwd)/Sources/App/Model.swift:7:// TODO(ixxxxoooo): 拆分")),
            .tool(ScenarioTool(id: "t_glob", title: "查找 *.swift", kind: "search", name: "Glob",
                               input: ["pattern": "**/*.swift"], output: "\(main)\n\(cwd)/Sources/App/Util.swift\n\(cwd)/Package.swift")),
            .tool(ScenarioTool(id: "t_write", title: "写入 NOTES.md", kind: "edit", name: "Write",
                               input: ["file_path": .string(cwd + "/NOTES.md")],
                               extra: [["type": "diff", "path": .string(cwd + "/NOTES.md"), "newText": "# 笔记\n\n- 第一条\n- 第二条\n"]],
                               locations: [["path": .string(cwd + "/NOTES.md")]])),
            .tool(ScenarioTool(id: "t_edit", title: "编辑 main.swift", kind: "edit", name: "Edit",
                               input: ["file_path": .string(main)],
                               extra: [["type": "diff", "path": .string(main), "oldText": "let app = App(debug: false)\napp.run()\n", "newText": "let app = App(debug: true)\napp.configure()\napp.run()\n"]],
                               locations: [["path": .string(main), "line": 1]])),
            .tool(ScenarioTool(id: "t_bash", title: "运行 swift test", kind: "execute", name: "Bash",
                               input: ["command": "swift test --filter Tool", "description": "运行工具相关测试"],
                               output: "\u{1B}[32m✔\u{1B}[0m Test one passed\n\u{1B}[31m✘\u{1B}[0m Test two failed\n\u{1B}[1;33mwarning:\u{1B}[0m something\nexit 1")),
            .tool(ScenarioTool(id: "t_mcp", title: "mcp__github__create_issue", kind: "other", name: "mcp__github__create_issue",
                               input: ["title": "修复崩溃", "repo": "ixxxxoooo/demo"], output: "{\"number\": 42}")),
            .tool(ScenarioTool(id: "t_fetch", title: "获取 example.com", kind: "fetch", name: "WebFetch",
                               input: ["url": "https://example.com/docs"], output: "Example Domain")),
            .tool(ScenarioTool(id: "t_fail", title: "运行 false", kind: "execute", name: "Bash",
                               input: ["command": "false"], output: "command failed with exit code 1", finish: .failed)),
        ]
    }

    /// `#mermaid`:各图种与一个不支持类型(验证回退)。
    static let legacyMermaid = DemoScenario(id: "legacy-mermaid", group: "legacy", title: "Mermaid 图", summary: "旧关键字 #mermaid") { _ in
        [.text(mermaidBlocks)]
    }

    /// Mermaid 示例代码块(每块一个分片)。
    static let mermaidBlocks = [
        "```mermaid\nflowchart TD\n  A[用户请求] --> B{已登录?}\n  B -->|是| C[读取数据]\n  B -->|否| D[跳转登录]\n  D --> A\n  C --> E([完成])\n  subgraph 后端\n    C --> F[(数据库)]\n  end\n```\n\n",
        "```mermaid\nsequenceDiagram\n  autonumber\n  participant U as 用户\n  participant S as 服务\n  U->>+S: 发起请求\n  S-->>-U: 返回结果\n  Note over U,S: 完成\n  loop 每分钟\n    U->>U: 自检\n  end\n```\n\n",
        "```mermaid\nstateDiagram-v2\n  [*] --> Idle\n  Idle --> Running : start\n  Running --> Idle : stop\n  Running --> [*]\n```\n\n",
        "```mermaid\nclassDiagram\n  class Animal {\n    +String name\n    +eat() void\n  }\n  Animal <|-- Dog\n  Animal <|-- Cat\n```\n\n",
        "```mermaid\npie showData title 占比\n  \"甲\" : 30\n  \"乙\" : 50\n  \"丙\" : 20\n```\n\n",
        "```mermaid\ngantt\n  title 计划\n  dateFormat YYYY-MM-DD\n  section 设计\n  调研 :done, a1, 2026-01-01, 5d\n  方案 :a2, after a1, 3d\n  section 开发\n  实现 :crit, 2026-01-10, 2026-01-20\n```\n\n",
        "```mermaid\nerDiagram\n  A ||--o{ B : has\n```\n\n",
    ]

    // MARK: 演示目录

    /// 演示场景目录(见 `DemoScenarios+Catalog.swift`)。
    static var catalog: [DemoScenario] { orderedCatalog }

    /// 分组的展示顺序(命令面板与斜杠补全按此排列;组内保持注册顺序)。
    static let groupOrder = ["全景", "工具卡", "交互", "会话流样式", "子 Agent", "状态与错误", "输入区与模式", "IDE 模式", "性能实验室", "回归"]

    /// 按分组顺序稳定排序后的目录;未登记的分组排在最后。
    private static let orderedCatalog: [DemoScenario] = {
        let rank = { (group: String) in groupOrder.firstIndex(of: group) ?? groupOrder.count }
        return catalogScenarios.enumerated()
            .sorted { (rank($0.element.group), $0.offset) < (rank($1.element.group), $1.offset) }
            .map(\.element)
    }()
}
