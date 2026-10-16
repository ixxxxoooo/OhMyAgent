// @author ixxxxoooo
// 自动化表单草稿:把界面上的分散字段(调度类型、分钟数、时刻、星期、cron)与 `Automation` 互相转换。

import Foundation

/// 调度类型(表单中的分段选项)。
public enum AutomationScheduleKind: String, CaseIterable, Sendable {
    case interval, daily, weekly, cron

    /// 界面名称。
    public var title: String {
        switch self {
        case .interval: return String(localized: "间隔")
        case .daily: return String(localized: "每天")
        case .weekly: return String(localized: "每周")
        case .cron: return "cron"
        }
    }
}

/// 自动化表单草稿。
public struct AutomationDraft: Equatable, Sendable {
    /// 正在编辑的自动化 ID;新建为 nil
    public var id: UUID?
    public var name = ""
    public var prompt = ""
    public var projectPath = ""
    public var permissionMode: AutomationPermissionMode = .readOnly
    public var enabled = true
    public var kind: AutomationScheduleKind = .daily
    public var intervalMinutes = 60
    public var hour = 9
    public var minute = 0
    /// 每周触发的星期(`Calendar` 编号:1 = 周日 … 7 = 周六)
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var cronExpression = "0 9 * * 1-5"

    public init() {}

    /// 由已有自动化生成草稿(编辑)。
    public init(automation: Automation) {
        id = automation.id
        name = automation.name
        prompt = automation.prompt
        projectPath = automation.projectPath
        permissionMode = automation.permissionMode
        enabled = automation.enabled
        apply(schedule: automation.schedule)
    }

    /// 由模板生成草稿(新建)。
    /// - Parameters:
    ///   - template: 模板
    ///   - projectPath: 默认项目目录
    public init(template: AutomationTemplate, projectPath: String) {
        name = template.name
        prompt = template.prompt
        self.projectPath = projectPath
        permissionMode = template.permissionMode
        apply(schedule: template.schedule)
    }

    /// 草稿对应的调度。
    public var schedule: AutomationSchedule {
        switch kind {
        case .interval: return .interval(minutes: intervalMinutes)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekly: return .weekly(weekdays: weekdays.sorted(), hour: hour, minute: minute)
        case .cron: return .cron(cronExpression.trimmingCharacters(in: .whitespaces))
        }
    }

    /// 生成自动化(保留编辑对象的 ID)。
    /// - Parameter createdAt: 新建时的创建时间
    public func makeAutomation(createdAt: Date = Date()) -> Automation {
        Automation(
            id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
            projectPath: projectPath, permissionMode: permissionMode, enabled: enabled, schedule: schedule, createdAt: createdAt)
    }

    /// 校验草稿。
    /// - Returns: 第一条错误提示;合法时为 nil
    public func validationMessage() -> String? { makeAutomation().validationMessage() }

    private mutating func apply(schedule: AutomationSchedule) {
        switch schedule {
        case .interval(let minutes): kind = .interval; intervalMinutes = minutes
        case .daily(let hour, let minute): kind = .daily; self.hour = hour; self.minute = minute
        case .weekly(let days, let hour, let minute): kind = .weekly; weekdays = Set(days); self.hour = hour; self.minute = minute
        case .cron(let expression): kind = .cron; cronExpression = expression
        }
    }
}
