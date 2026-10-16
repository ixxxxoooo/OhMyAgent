// @author ixxxxoooo
// 自动化模板库:常用的巡检/摘要类任务,一键填入表单。

import Foundation

/// 自动化模板。
public struct AutomationTemplate: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var prompt: String
    public var schedule: AutomationSchedule
    public var permissionMode: AutomationPermissionMode

    /// 内置模板(均为只读,不会改动项目文件)。
    public static var all: [AutomationTemplate] {
        [
            AutomationTemplate(
                id: "daily-digest", name: String(localized: "每日变更摘要"),
                summary: String(localized: "每个工作日早上汇总过去 24 小时的提交与改动"),
                prompt: String(localized: "请查看这个仓库过去 24 小时的 git 提交与未提交改动,用简洁的要点总结:谁改了什么、有哪些值得关注的风险或遗留问题。不要修改任何文件。"),
                schedule: .cron("0 9 * * 1-5"), permissionMode: .readOnly),
            AutomationTemplate(
                id: "weekly-deps", name: String(localized: "每周依赖检查"),
                summary: String(localized: "每周一检查依赖是否过期或存在已知风险"),
                prompt: String(localized: "请检查这个项目的依赖清单,列出明显过期、已废弃或存在已知安全风险的依赖,并给出升级建议与风险评估。不要修改任何文件。"),
                schedule: .weekly(weekdays: [2], hour: 10, minute: 0), permissionMode: .readOnly),
            AutomationTemplate(
                id: "todo-sweep", name: String(localized: "待办扫描"),
                summary: String(localized: "每天傍晚整理代码里的 TODO / FIXME"),
                prompt: String(localized: "请扫描代码里的 TODO、FIXME 注释,按模块分组并标出最久远、最可能影响功能的几项。不要修改任何文件。"),
                schedule: .daily(hour: 18, minute: 0), permissionMode: .readOnly),
            AutomationTemplate(
                id: "branch-hygiene", name: String(localized: "分支整理提醒"),
                summary: String(localized: "每周五列出已合并或长期未动的分支"),
                prompt: String(localized: "请列出这个仓库里已经合并到主分支、或超过 30 天没有提交的本地分支,给出可以安全删除的清单。不要执行任何删除操作。"),
                schedule: .weekly(weekdays: [6], hour: 17, minute: 30), permissionMode: .readOnly),
        ]
    }
}
