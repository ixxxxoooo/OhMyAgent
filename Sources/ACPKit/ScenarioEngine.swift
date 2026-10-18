// @author ixxxxoooo
// 场景引擎的数据模型:把脚本化 Agent 的行为描述为声明式步骤(纯数据,可被测试与演示模式复用)。
// 引擎本身(执行步骤)见 `ScriptedAgent+Engine.swift`,内置场景目录见 `DemoScenarios.swift`。

import Foundation

/// 场景执行上下文(构建步骤时可读取工作区路径等运行时信息)。
public struct ScenarioContext: Sendable {
    /// 会话工作目录
    public var cwd: String
    /// 会话 ID
    public var sessionId: String
    /// 工具调用 ID 后缀:同一会话多次运行同一场景时保证卡片不被复用(旧关键字为空,保持原 ID)
    public var idSuffix: String

    public init(cwd: String, sessionId: String, idSuffix: String = "") {
        self.cwd = cwd
        self.sessionId = sessionId
        self.idSuffix = idSuffix
    }

    /// 给工具调用 ID 追加本次运行的后缀。
    /// - Parameter id: 场景里写的原始 ID
    public func scoped(_ id: String) -> String { id + idSuffix }
}

/// 工具调用的最终状态。
public enum ScenarioFinish: Sendable, Equatable {
    /// 完成
    case completed
    /// 失败
    case failed
    /// 保持「进行中」不再结束(冻结态,用于检查转圈与任务坞)
    case running
    /// 保持「待处理」不再推进
    case pending
}

/// 一次工具调用(进行中 → 结束)。
public struct ScenarioTool: Sendable {
    public var id: String
    public var title: String
    /// ACP 工具类别:read / edit / delete / move / search / execute / think / fetch / switch_mode / other
    public var kind: String
    /// Claude 工具名,如 Read、Bash、mcp__github__create_issue
    public var name: String
    public var input: JSONValue
    /// 文本输出
    public var output: String?
    /// 额外内容块(Diff、终端等)
    public var extra: [JSONValue]
    public var finish: ScenarioFinish
    public var locations: JSONValue

    public init(
        id: String, title: String, kind: String, name: String, input: JSONValue = .object([:]),
        output: String? = nil, extra: [JSONValue] = [], finish: ScenarioFinish = .completed, locations: JSONValue = .array([])
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.name = name
        self.input = input
        self.output = output
        self.extra = extra
        self.finish = finish
        self.locations = locations
    }
}

/// 权限请求的选项集合。
public enum ScenarioPermissionOptions: Sendable {
    /// 允许一次 / 拒绝
    case standard
    /// 允许一次 / 始终允许 / 拒绝
    case withAlways
    /// 计划批准:自动接受编辑 / 逐项确认 / 继续规划
    case plan
}

/// 需要用户批准的工具调用。
public struct ScenarioPermission: Sendable {
    public var tool: ScenarioTool
    public var options: ScenarioPermissionOptions
    /// 拒绝后助手补充的文字
    public var rejectedText: String

    public init(tool: ScenarioTool, options: ScenarioPermissionOptions = .standard, rejectedText: String = "已取消修改。") {
        self.tool = tool
        self.options = options
        self.rejectedText = rejectedText
    }
}

/// 子 Agent(Task 工具)及其内部步骤。
public struct ScenarioSubagent: Sendable {
    public var id: String
    /// 工具卡标题
    public var title: String
    /// 子 Agent 类型,如 Explore、code-reviewer
    public var agentType: String?
    /// 是否后台运行
    public var background: Bool
    /// 子 Agent 内部的步骤(产生带父 ID 的更新,可再嵌套子 Agent)
    public var children: [ScenarioStep]
    public var finish: ScenarioFinish
    /// 子 Agent 结束时返回给父会话的结论文本
    public var result: String?

    public init(
        id: String, title: String, agentType: String? = nil, background: Bool = false,
        children: [ScenarioStep], finish: ScenarioFinish = .completed, result: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agentType = agentType
        self.background = background
        self.children = children
        self.finish = finish
        self.result = result
    }
}

/// 计划条目(待办)。
public struct ScenarioPlanItem: Sendable {
    public var content: String
    public var priority: String
    public var status: String

    public init(_ content: String, priority: String = "medium", status: String = "pending") {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// 需要真实副作用或反向请求的内置步骤(沿用既有 `#edit` / `#ask` / `#term` / `#hold`)。
public enum ScenarioBuiltin: Sendable {
    /// 真实修改工作区 `oma-demo.txt` 并请求权限
    case edit
    /// 发起 AskUserQuestion 表单
    case ask
    /// 通过客户端终端执行命令
    case terminal
    /// 长时间占用:挂起约 20 秒的终端与未完成的子 Agent
    case longRunning
}

/// 套餐限额窗口(经 `usage_update._meta["_claude/rateLimit"]` 转发)。
public struct ScenarioRateWindow: Sendable {
    /// 窗口类型:five_hour / seven_day / seven_day_opus / seven_day_sonnet
    public var type: String
    /// 已用比例 0...1
    public var utilization: Double
    /// 距重置的分钟数
    public var resetsInMinutes: Int

    public init(_ type: String, _ utilization: Double, resetsInMinutes: Int) {
        self.type = type
        self.utilization = utilization
        self.resetsInMinutes = resetsInMinutes
    }
}

/// 场景步骤。
public enum ScenarioStep: Sendable {
    /// 思维流分片
    case thought([String])
    /// 助手文本分片
    case text([String])
    /// 用户消息(历史回放使用)
    case user(String)
    /// 用户消息里的图片(紧随 `.user` 之后发出,合并进同一条用户消息)
    case userImage(ScenarioImageKind)
    /// 工具调用
    case tool(ScenarioTool)
    /// 需批准的工具调用
    case permission(ScenarioPermission)
    /// 子 Agent
    case subagent(ScenarioSubagent)
    /// 并行执行多组步骤(用于并行子 Agent)
    case parallel([[ScenarioStep]])
    /// 计划(待办)
    case plan([ScenarioPlanItem])
    /// 计划文档(Markdown)
    case planDoc(String)
    /// 会话提示
    case notice(severity: String, title: String, detail: String?)
    /// 第三方 Agent 的扩展通知(pi-acp 以带 `_meta.piAcp.notify` 的消息分片发出,如 pi-tps 的 TPS 行)
    case agentNotify(level: String, text: String)
    /// 用量更新
    case usage(used: Int, size: Int, cost: Double?)
    /// 会话标题更新
    case title(String)
    /// 切换模式
    case mode(String)
    /// 套餐限额更新(一组窗口同时给出)
    case rateLimit([ScenarioRateWindow])
    /// 以指定停止原因结束本轮:`refusal` / `max_tokens` / `max_turn_requests`(后续步骤不再执行)
    case stop(String)
    /// 让本轮的 `session/prompt` 以 JSON-RPC 错误失败(如 -32000 鉴权失败、限流、提示渲染失败)
    case fail(code: Int, message: String)
    /// 停顿(毫秒,会按节奏缩放)
    case delay(Int)
    /// 永不结束,直到被取消(冻结态)
    case hold
    /// 内置步骤
    case builtin(ScenarioBuiltin)
}

/// 场景执行结果。
public enum ScenarioOutcome: Sendable, Equatable {
    /// 全部步骤执行完
    case finished
    /// 被取消
    case cancelled
    /// 用户拒绝了权限,轮次应直接结束
    case rejected
    /// 场景要求以该停止原因结束本轮
    case stopped(String)
}
