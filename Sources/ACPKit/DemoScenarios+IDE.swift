// @author ixxxxoooo
// IDE 模式演示场景:Agent 改动在编辑器里的行内审阅(保留 / 还原)与 Composer 多文件审阅。
// 文件改动是真实写盘(与 `changes` 场景同一套权限与检查点流程),便于在 IDE 窗口验证行内 Diff 与改动汇总。

import Foundation

extension DemoScenarios {
    /// IDE 模式相关场景。
    static var ideScenarios: [DemoScenario] {
        [
            DemoScenario(id: "inline-edit", group: "IDE 模式", title: "行内审阅:Agent 修改一个文件", summary: "真实修改 oma-demo.txt;在 IDE 窗口打开该文件即可看到绿色新增行、红色删除块与「保留 / 还原」块头条;也可在编辑器里选中几行按 ⌘K 试行内编辑(交互)", behavior: .interactive, build: ideInlineEdit),
            DemoScenario(id: "composer-review", group: "IDE 模式", title: "Composer 审阅:Agent 同时改多个文件", summary: "真实修改 3 个文件;在 IDE 里从命令面板「打开 Composer 审阅」或点击改动汇总的 Review,逐文件查看并整体保留/撤销(交互)", behavior: .interactive, build: ideComposerReview),
        ]
    }

    /// 单文件改动:先说明再真实改写。
    static func ideInlineEdit(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("我会真实修改工作区里的 `oma-demo.txt`。在 IDE 窗口打开它,改动会以行内 Diff 显示,每个块都能单独「保留」或「还原」。\n\n"),
            .builtin(.edit),
            DemoSteps.say("修改完成。选中几行按 ⌘K 还能让模型就地改写,⌘⏎ 接受、Esc 拒绝。\n"),
        ]
    }

    /// 多文件改动:三个文件依次改写,收尾引导到 Composer 审阅。
    static func ideComposerReview(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            DemoSteps.say("这次我会同时改动三个文件,稍后可以在 Composer 审阅里统一查看。\n\n"),
            .builtin(.editFile("oma-demo.txt")),
            .builtin(.editFile("oma-demo-notes.txt")),
            .builtin(.editFile("oma-demo-config.txt")),
            DemoSteps.say("三处改动都已完成。打开 Composer 审阅可以逐文件检查,也可以一键撤销全部。\n"),
        ]
    }
}
