// @author ixxxxoooo
// 回合与后台任务的内部状态类型。

import ACPKit
import Foundation

/// 一个回合的收尾结果。
struct PromptOutcome: Sendable {
    var stopReason: String
    var usage: JSONValue
    var meta: JSONValue

    /// `session/prompt` 响应体。
    var response: JSONValue {
        ["stopReason": .string(stopReason), "usage": usage, "_meta": meta]
    }
}

/// 排队中的一个回合(对应一次 `session/prompt`)。仅在会话 actor 内使用。
final class SessionTurn {
    /// 发给 CLI 的用户消息 UUID(回放确认与结果匹配用)
    let promptUuid: String
    /// 是否为只在本地执行的命令(如 `/context`)
    let isLocalOnly: Bool
    /// 是否已收尾
    var settled = false
    /// 回合已出结果、但后台子代理仍在跑时暂存的收尾结果(等 `idle` 再交付)
    var deferredSettle: PromptOutcome?
    /// 尚未被结果回应的引导消息 UUID
    var steeredEchoes: Set<String> = []
    /// 引导消息 UUID 全集(取消时一并标记)
    var steeredUuids: Set<String> = []
    /// 引导消息已被 CLI 回放确认,正等它的结果
    var steeredAwaitingResult = false
    /// 引导期间提前到达的结果(等引导消息被回应后交付)
    var steeredSettle: PromptOutcome?
    /// 本回合期间启动的后台任务 ID(用于判断是否还要等子代理)
    var spawnedTaskIds: Set<String> = []
    /// 本回合已展示的提示文本(去重 `result` 正文)
    var noticeTexts: [String] = []
    private let sink: AsyncThrowingStream<PromptOutcome, Error>.Continuation

    init(promptUuid: String, isLocalOnly: Bool, sink: AsyncThrowingStream<PromptOutcome, Error>.Continuation) {
        self.promptUuid = promptUuid
        self.isLocalOnly = isLocalOnly
        self.sink = sink
    }

    /// 以成功结果收尾。
    func resolve(_ outcome: PromptOutcome) {
        guard !settled else { return }
        settled = true
        sink.yield(outcome)
        sink.finish()
    }

    /// 以错误收尾。
    func reject(_ error: Error) {
        guard !settled else { return }
        settled = true
        sink.finish(throwing: error)
    }

    /// 是否处在「引导进行中」:有引导消息尚未被结果回应。
    var isSteering: Bool { !steeredEchoes.isEmpty || steeredAwaitingResult }

    /// 是否被后台任务拖住(已出结果但还没交付)。
    var isHeldOpen: Bool { deferredSettle != nil }
}

/// 仍在运行的后台任务(子代理、后台命令、工作流)。
struct LiveTask: Sendable {
    var taskType: String
    var parentToolUseId: String?
    var isSubagent: Bool
    var description: String
    var runId: String?
}

/// 初始化阶段登记给 CLI 的钩子类别。
enum HookKind: String, Sendable {
    case postToolUse = "PostToolUse"
    case postModelSwitch = "PostModelSwitch"
    case postCompact = "PostCompact"
    case taskCreated = "TaskCreated"
    case taskCompleted = "TaskCompleted"
}

/// 会话创建选项。
struct SessionCreation: Sendable {
    /// 恢复的会话 ID(`--resume`)
    var resume: String?
    /// 恢复时分叉为新会话
    var fork = false
    /// 复用的会话 ID(从未持久化过的会话以同一 ID 重开)
    var reuseSessionId: String?
    /// 显式权限模式(重建时沿用当前模式)
    var permissionMode: String?
    /// 外部已知的恢复模型(nil 表示自己读转录)
    var resumedModelHint: String??
}
