// @author ixxxxoooo
// 演示历史会话目录:每个演示项目预置 8~12 条历史会话(长短标题、置顶、归档),
// 点开时由 `session/load` 回放完整内容(工具卡、子 Agent、Diff、计划文档),历史里即是一页「静态图集」。

import Foundation

/// 一条演示历史会话。
public struct DemoHistorySession: Sendable, Identifiable {
    /// 回放内容来源
    public enum Body: Sendable {
        /// 引用场景目录里的场景(交互/冻结步骤在回放时被规整为已完成)
        case scenario(String)
        /// 简短问答
        case qa([String])
    }

    /// 会话 ID(全局唯一,形如 `demo-atlas-web-1`)
    public let id: String
    /// 所属演示项目名
    public let project: String
    /// 会话标题
    public let title: String
    /// 首条用户消息
    public let prompt: String
    /// 距现在多少分钟前更新(越小越新)
    public let minutesAgo: Int
    /// 是否在项目树中置顶
    public let pinned: Bool
    /// 是否已归档
    public let archived: Bool
    /// 回放内容
    public let body: Body

    /// - Parameters:
    ///   - index: 项目内序号(拼接会话 ID)
    ///   - project: 项目名
    ///   - title: 标题
    ///   - prompt: 首条用户消息
    ///   - minutesAgo: 距现在分钟数
    ///   - pinned: 是否置顶
    ///   - archived: 是否归档
    ///   - body: 回放内容
    public init(index: Int, project: String, title: String, prompt: String, minutesAgo: Int, pinned: Bool = false, archived: Bool = false, body: Body) {
        self.id = "demo-\(project)-\(index)"
        self.project = project
        self.title = title
        self.prompt = prompt
        self.minutesAgo = minutesAgo
        self.pinned = pinned
        self.archived = archived
        self.body = body
    }

    /// 更新时间(ISO8601)。
    /// - Parameter now: 基准时间
    public func updatedAt(now: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
    }
}

/// 演示历史会话目录。
public enum DemoHistory {
    /// 全部演示历史会话。
    public static let all: [DemoHistorySession] = atlas + notes + mergeLab + legacy + emptyProject

    /// 某个项目的历史会话(新→旧)。
    /// - Parameter project: 项目名
    public static func sessions(forProject project: String) -> [DemoHistorySession] {
        all.filter { $0.project == project }.sorted { $0.minutesAgo < $1.minutesAgo }
    }

    /// 按会话 ID 查找。
    /// - Parameter id: 会话 ID
    public static func session(id: String) -> DemoHistorySession? { all.first { $0.id == id } }

    /// 生成回放步骤:首条用户消息 + 规整后的内容。
    /// - Parameters:
    ///   - session: 历史会话
    ///   - ctx: 上下文(工作目录用于拼接文件路径)
    public static func replaySteps(for session: DemoHistorySession, ctx: ScenarioContext) -> [ScenarioStep] {
        var steps: [ScenarioStep] = [.user(session.prompt)]
        switch session.body {
        case .scenario(let id):
            if let scenario = DemoScenarios.scenario(named: id) { steps += normalize(scenario.build(ctx)) }
        case .qa(let lines):
            steps.append(.text(lines))
        }
        return steps
    }

    /// 把「正在发生」的场景步骤规整为「已经发生」:去掉停顿/冻结/内置交互与回合终止/报错/限额,权限请求变为已完成的工具,冻结的工具改为完成,并行改为顺序。
    /// - Parameter steps: 原步骤
    public static func normalize(_ steps: [ScenarioStep]) -> [ScenarioStep] {
        steps.flatMap { step -> [ScenarioStep] in
            switch step {
            case .delay, .hold, .builtin, .mode, .title, .stop, .fail, .rateLimit, .elicit, .elicitURL:
                return []
            case .tool(var tool):
                tool.finish = settled(tool.finish)
                return [.tool(tool)]
            case .permission(let permission):
                var tool = permission.tool
                tool.finish = settled(tool.finish)
                return [.tool(tool)]
            case .subagent(var sub):
                sub.finish = settled(sub.finish)
                sub.background = false
                sub.children = normalize(sub.children)
                return [.subagent(sub)]
            case .parallel(let groups):
                return groups.flatMap { normalize($0) }
            default:
                return [step]
            }
        }
    }

    private static func settled(_ finish: ScenarioFinish) -> ScenarioFinish {
        finish == .failed ? .failed : .completed
    }
}

// MARK: 目录数据

extension DemoHistory {
    private static func make(_ project: String, _ items: [(String, String, Int, Bool, Bool, DemoHistorySession.Body)]) -> [DemoHistorySession] {
        items.enumerated().map { offset, item in
            DemoHistorySession(index: offset + 1, project: project, title: item.0, prompt: item.1, minutesAgo: item.2, pinned: item.3, archived: item.4, body: item.5)
        }
    }

    static let atlas = make("atlas-web", [
        ("梳理 AtlasCore 路由架构", "帮我梳理一下 AtlasCore 的路由架构,列出主要文件和调用关系", 5, true, false, .scenario("tools-files")),
        ("修复路由大小写匹配", "路由匹配对大小写敏感,/Users 和 /users 被当成两条路由,帮我修一下", 38, false, false, .scenario("tools-plan-todo")),
        ("接入 Metrics 指标上报", "给 Router 加上请求耗时与命中率的指标上报", 130, false, false, .scenario("permissions")),
        ("为 Session 增加超时与重试", "Session 需要支持空闲超时和重试,先让几个子 Agent 分别调研再动手", 1_500, true, false, .scenario("subagents")),
        ("并行审查三个模块", "同时审查 Router、Session、Cache 三个模块的并发安全", 1_700, false, false, .scenario("subagents-parallel")),
        ("发布前检查清单", "跑一遍发布前检查:构建、测试、lint、依赖审计", 2_900, false, false, .scenario("tools-shell")),
        ("调研同类框架的缓存策略", "调研一下同类 Web 框架的缓存失效策略,给出对比", 4_400, false, false, .scenario("tools-web-mcp")),
        ("架构文档与时序图", "把路由与会话的交互画成时序图写进 docs/architecture.md", 5_800, false, false, .scenario("mermaid")),
        ("Markdown 与代码高亮样式检查", "输出一份包含各种 Markdown 元素和多语言代码块的样例", 7_200, false, false, .scenario("markdown")),
        ("排查缓存命中率下降的原因并给出基于最近三次发布差异的分析与回滚建议", "最近三次发布后缓存命中率一路下降,帮我排查原因并给出回滚建议", 8_700, false, true, .scenario("states-errors")),
        ("hi", "hi", 11_500, false, true, .qa(["你好!我在 atlas-web 项目里,可以帮你读代码、改代码、跑命令。想先做点什么?"])),
        ("Refactor the Legacy util module to remove global state", "Refactor the Legacy util module so it no longer relies on global mutable state.", 14_400, false, false, .scenario("states-notices")),
    ])

    static let notes = make("notes-cli", [
        ("添加 --json 输出", "给 list 命令加一个 --json 选项", 12, false, false, .scenario("tools-files")),
        ("修复标签解析", "带中文的标签解析会截断,看看哪里出问题", 95, true, false, .scenario("tools-plan-todo")),
        ("补全单元测试", "给 notes-cli 补一些单元测试", 600, false, false, .scenario("tools-shell")),
        ("README 重写", "重写 README,突出安装与示例", 1_800, false, false, .scenario("markdown")),
        ("选择存储格式", "笔记存储用 JSON 还是 SQLite?帮我权衡", 3_000, false, false, .scenario("ask")),
        ("发布 0.2.0", "准备发布 0.2.0,整理变更日志", 6_000, false, false, .scenario("tools-web-mcp")),
        ("一个很短的问题", "怎么在 zsh 里补全 notes 命令?", 9_000, false, true, .qa(["可以用 `notes completion zsh > ~/.zsh/completions/_notes`,然后确保 `fpath` 包含该目录并重新执行 `compinit`。"])),
        ("清理过期笔记命令", "加一个 purge 命令清理 90 天前的笔记", 12_000, false, false, .scenario("changes")),
    ])

    static let mergeLab = make("merge-lab", [
        ("解决 config.yaml 冲突", "合并 topic 分支时 config.yaml 冲突了,帮我看看怎么解", 3, true, false, .scenario("tools-plan-todo")),
        ("解释 calc.py 的冲突", "calc.py 里 <<<<<<< 标记两边分别是什么意图?", 40, false, false, .scenario("tools-files")),
        ("选择合并还是变基", "这个分支该 merge 还是 rebase?", 400, false, false, .scenario("ask")),
        ("回滚错误合并", "刚才的合并合错分支了,怎么安全回滚", 1_400, false, false, .scenario("tools-shell")),
        ("冲突处理最佳实践", "总结一下处理合并冲突的最佳实践", 2_600, false, false, .scenario("markdown")),
        ("检查 scratch.txt 是否该提交", "scratch.txt 是临时文件,该忽略吗", 4_000, false, true, .qa(["`scratch.txt` 看起来是调试用的临时文件,建议加入 `.gitignore` 而不是提交。"])),
        ("审查冲突解决结果", "用子 Agent 审查一下我解决冲突后的代码", 5_500, false, false, .scenario("subagents")),
        ("生成合并说明", "为这次合并写一段说明", 8_000, false, false, .scenario("roles")),
    ])

    static let legacy = make("legacy-api", [
        ("这个目录不是 Git 仓库", "为什么源代码管理面板是空的?", 20, false, false, .qa(["这个目录没有初始化 Git 仓库,所以源代码管理面板显示「不是仓库」。可以运行 `git init` 开始管理,我也可以代劳。"])),
        ("盘点遗留接口", "列出所有遗留接口并标注是否仍在使用", 160, true, false, .scenario("tools-files")),
        ("接口迁移计划", "给出把这些接口迁移到新框架的计划", 900, false, false, .scenario("plan-approval")),
        ("调研 OpenAPI 生成方案", "有没有工具能从现有接口反推 OpenAPI?", 2_000, false, false, .scenario("tools-web-mcp")),
        ("并行扫描依赖", "并行扫描各模块的第三方依赖与许可证", 3_300, false, false, .scenario("subagents-parallel")),
        ("导出接口文档", "把接口文档导出成 Markdown", 5_000, false, false, .scenario("markdown")),
        ("遗留代码风险图", "画一张遗留代码的风险热力图", 7_000, false, false, .scenario("mermaid")),
        ("初始化仓库", "帮我 git init 并做首次提交", 10_000, false, true, .scenario("states-notices")),
    ])

    static let emptyProject = make("empty-project", [
        ("从零搭一个项目", "这是个空目录,帮我搭一个最小的 Swift 命令行项目", 8, false, false, .scenario("tools-plan-todo")),
        ("选择技术栈", "我想做个记账工具,用什么技术栈合适?", 70, true, false, .scenario("ask")),
        ("生成 .gitignore", "生成一个适合 Swift 项目的 .gitignore", 500, false, false, .scenario("tools-files")),
        ("写一份项目计划", "写一份两周的项目计划", 1_600, false, false, .scenario("plan-approval")),
        ("搭建脚手架", "用子 Agent 分别搭建 CLI、核心库与测试", 2_800, false, false, .scenario("subagents")),
        ("你好", "你好", 4_200, false, false, .qa(["你好!这是一个空目录,告诉我你想做什么,我来帮你起步。"])),
        ("样式检查", "输出各种样式样例", 6_400, false, true, .scenario("roles")),
        ("评估许可证选择", "开源许可证选 MIT 还是 Apache-2.0?", 9_600, false, false, .scenario("tools-web-mcp")),
    ])
}
