// @author ixxxxoooo
// 自动化数据模型:自动化定义、运行记录、权限模式与持久化库(值类型,可编码)。

import Foundation

/// 无人值守时使用的权限模式(决定 Agent 能做什么;需要额外授权的操作会被自动拒绝)。
public enum AutomationPermissionMode: String, Codable, CaseIterable, Sendable {
    /// 只读规划:读取与分析,不改文件
    case readOnly
    /// 自动接受文件编辑,其它需要授权的操作被拒绝
    case acceptEdits

    /// 对应 ACP `mode` 配置项的取值。
    public var acpValue: String {
        switch self {
        case .readOnly: return "plan"
        case .acceptEdits: return "acceptEdits"
        }
    }

    /// 界面名称。
    public var title: String {
        switch self {
        case .readOnly: return String(localized: "只读(不修改文件)")
        case .acceptEdits: return String(localized: "自动接受编辑")
        }
    }
}

/// 一个自动化:在指定项目里按调度向 Agent 发送提示词。
public struct Automation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 发送给 Agent 的提示词
    public var prompt: String
    /// 项目目录(绝对路径)
    public var projectPath: String
    public var permissionMode: AutomationPermissionMode
    public var enabled: Bool
    public var schedule: AutomationSchedule
    public var createdAt: Date
    /// 最近一次运行开始时间(仅用于展示)
    public var lastRunAt: Date?
    /// 调度基准:启用、修改调度或运行后更新;下一次触发从它之后算起,避免重新启用时立即补跑陈年任务
    public var baseline: Date

    /// 名称长度上限。
    public static let maxNameLength = 80
    /// 提示词长度上限。
    public static let maxPromptLength = 8000

    public init(
        id: UUID = UUID(), name: String, prompt: String, projectPath: String,
        permissionMode: AutomationPermissionMode = .acceptEdits, enabled: Bool = true,
        schedule: AutomationSchedule, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.projectPath = projectPath
        self.permissionMode = permissionMode
        self.enabled = enabled
        self.schedule = schedule
        self.createdAt = createdAt
        self.baseline = createdAt
    }

    /// 校验表单内容。
    /// - Returns: 第一条错误提示;合法时为 nil
    public func validationMessage() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "请填写名称") }
        if name.count > Self.maxNameLength { return String(localized: "名称不能超过 \(Self.maxNameLength) 字") }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "请填写要发送的提示词") }
        if prompt.count > Self.maxPromptLength { return String(localized: "提示词不能超过 \(Self.maxPromptLength) 字") }
        if projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "请先选择项目") }
        return schedule.validationMessage()
    }

    /// 下一次定时触发时间(未启用或调度非法时为 nil)。
    /// - Parameter calendar: 日历
    public func nextRun(calendar: Calendar = .current) -> Date? {
        enabled ? schedule.nextRun(after: baseline, calendar: calendar) : nil
    }

    /// 此刻是否到期:错过的触发(应用未运行期间)只补跑一次。
    /// - Parameters:
    ///   - now: 当前时间
    ///   - calendar: 日历
    public func isDue(now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextRun(calendar: calendar) else { return false }
        return next <= now
    }
}

/// 一次运行的触发来源。
public enum AutomationTrigger: String, Codable, Sendable {
    case schedule, manual
}

/// 运行状态。
public enum AutomationRunStatus: String, Codable, Sendable {
    case running, succeeded, failed, cancelled, timedOut

    /// 是否已结束。
    public var isFinished: Bool { self != .running }

    /// 界面名称。
    public var title: String {
        switch self {
        case .running: return String(localized: "运行中")
        case .succeeded: return String(localized: "成功")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已取消")
        case .timedOut: return String(localized: "已超时")
        }
    }
}

/// 一次运行记录。
public struct AutomationRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var automationID: UUID
    public var trigger: AutomationTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: AutomationRunStatus
    /// Agent 最后一条回复的摘要(或失败原因)
    public var summary: String
    /// 运行所用的 ACP 会话 ID(可在标签中打开续聊)
    public var sessionID: String?

    public init(
        id: UUID = UUID(), automationID: UUID, trigger: AutomationTrigger, startedAt: Date,
        finishedAt: Date? = nil, status: AutomationRunStatus = .running, summary: String = "", sessionID: String? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
        self.sessionID = sessionID
    }

    /// 耗时(秒);未结束为 nil。
    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// 持久化库:全部自动化与最近的运行记录。
public struct AutomationLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var automations: [Automation] = []
    public var runs: [AutomationRun] = []

    /// 每个自动化最多保留的运行记录数。
    public static let maxRunsPerAutomation = 30

    public init() {}

    /// 某自动化的运行记录(新的在前)。
    public func runs(for id: UUID) -> [AutomationRun] {
        runs.filter { $0.automationID == id }.sorted { $0.startedAt > $1.startedAt }
    }

    /// 追加或更新一条运行记录,并裁剪历史。
    public mutating func upsert(run: AutomationRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        let mine = runs(for: run.automationID)
        if mine.count > Self.maxRunsPerAutomation {
            let drop = Set(mine.suffix(mine.count - Self.maxRunsPerAutomation).map(\.id))
            runs.removeAll { drop.contains($0.id) }
        }
    }

    /// 删除自动化及其运行记录。
    public mutating func remove(automation id: UUID) {
        automations.removeAll { $0.id == id }
        runs.removeAll { $0.automationID == id }
    }
}
