// @author ixxxxoooo
// 演示场景:套餐限额逐步逼近、上下文接近上限后的压缩流程。
// 限额经 `usage_update._meta["_claude/rateLimit"]` 转发,上下文环与用量面板据此刷新。

import Foundation

extension DemoScenarios {
    /// 用量类场景。
    static let usageScenarios: [DemoScenario] = [
        DemoScenario(id: "usage-limits", group: "状态与错误", title: "套餐限额:5 小时与每周额度逐步逼近", summary: "上下文环从 45% 升到 94%,5 小时限额 82% → 97%,每周与 Opus 额度同时显示,可在用量面板查看", build: usageLimits),
        DemoScenario(id: "context-compact", group: "状态与错误", title: "上下文压缩:接近上限后自动摘要", summary: "上下文告急 → 压缩 → 用量回落 → 压缩完成提示", build: contextCompact),
    ]

    /// 套餐限额:三次用量更新,额度逐步升高。
    static func usageLimits(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("这是一个很长的重构任务,我先分析整体结构。\n\n"),
            .usage(used: 90_000, size: 200_000, cost: 0.46),
            .rateLimit([
                ScenarioRateWindow("five_hour", 0.82, resetsInMinutes: 47),
                ScenarioRateWindow("seven_day", 0.31, resetsInMinutes: 4 * 24 * 60 + 600),
                ScenarioRateWindow("seven_day_opus", 0.18, resetsInMinutes: 4 * 24 * 60 + 600),
            ]),
            .delay(300),
            DemoSteps.say("接着梳理依赖关系,涉及的模块比预期多。\n\n"),
            .usage(used: 150_000, size: 200_000, cost: 0.83),
            .rateLimit([
                ScenarioRateWindow("five_hour", 0.91, resetsInMinutes: 41),
                ScenarioRateWindow("seven_day", 0.34, resetsInMinutes: 4 * 24 * 60 + 590),
                ScenarioRateWindow("seven_day_opus", 0.21, resetsInMinutes: 4 * 24 * 60 + 590),
            ]),
            .delay(300),
            .notice(severity: "warning", title: "5 小时额度即将用尽", detail: "已使用 97%,约 36 分钟后重置。可以切换到更轻量的模型继续。"),
            .usage(used: 188_000, size: 200_000, cost: 1.12),
            .rateLimit([
                ScenarioRateWindow("five_hour", 0.97, resetsInMinutes: 36),
                ScenarioRateWindow("seven_day", 0.38, resetsInMinutes: 4 * 24 * 60 + 585),
                ScenarioRateWindow("seven_day_opus", 0.26, resetsInMinutes: 4 * 24 * 60 + 585),
            ]),
            DemoSteps.say("先到这里:上下文已接近上限。建议先执行 `/compact`,或新开一个对话继续。\n"),
        ]
    }

    /// 上下文压缩:告急 → 压缩 → 回落。
    static func contextCompact(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("继续处理剩下的模块。\n\n"),
            .usage(used: 186_000, size: 200_000, cost: 1.05),
            .notice(severity: "warning", title: "上下文接近上限", detail: "已使用 93%。接近上限时会自动压缩较早的消息。"),
            .delay(400),
            .notice(severity: "info", title: "正在压缩上下文", detail: nil),
            .delay(600),
            .usage(used: 38_000, size: 200_000, cost: 1.09),
            .notice(severity: "info", title: "上下文已压缩", detail: "较早的 142 条消息已被摘要,保留了最近的文件改动与待办。"),
            DemoSteps.say("压缩完成,我们继续。下一步处理 `Session` 模块。\n"),
        ]
    }
}
