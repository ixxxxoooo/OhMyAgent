// @author ixxxxoooo
// 演示场景:权限模式依次切换。输入区的模式标签与色调随 `current_mode_update` 变化。

import Foundation

extension DemoScenarios {
    /// 模式类场景。
    static let modeScenarios: [DemoScenario] = [
        DemoScenario(id: "modes-matrix", group: "输入区与模式", title: "权限模式:六种模式依次切换", summary: "Default / Accept Edits / Plan / Auto / Don't Ask / Bypass Permissions 依次切换,看输入区模式标签的色调变化", build: modesMatrix),
    ]

    /// 依次切换全部权限模式,每个模式停留片刻并给出一句说明。
    static func modesMatrix(_ c: ScenarioContext) -> [ScenarioStep] {
        let modes: [(id: String, note: String)] = [
            ("acceptEdits", "**Accept Edits**:文件编辑自动通过,命令仍需确认。"),
            ("plan", "**Plan Mode**:只读规划,不会修改任何文件。"),
            ("auto", "**Auto**:由分类器判断哪些操作需要你确认。"),
            ("dontAsk", "**Don't Ask**:不弹确认,只执行已在允许清单里的操作。"),
            ("bypassPermissions", "**Bypass Permissions**:跳过全部确认,请只在隔离环境里使用。"),
            ("default", "回到 **Default**:每次编辑与命令都会询问。"),
        ]
        var steps: [ScenarioStep] = [DemoSteps.say("我会依次切换各种权限模式,留意输入区左下角模式标签的颜色。\n\n")]
        for mode in modes {
            steps.append(.mode(mode.id))
            steps.append(DemoSteps.say(mode.note + "\n\n"))
            steps.append(.delay(500))
        }
        return steps
    }
}
