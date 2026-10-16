// @author ixxxxoooo
// 演示模式的命令面板入口:「演示场景」命令组,每个场景一条,选中后在当前会话运行(等价于输入 `/demo-<名>`)。

import ACPKit
import ChatKit
import Foundation
import WorkbenchKit

@MainActor
enum DemoPaletteCommands {
    /// 演示场景命令;非演示模式返回空。
    /// - Parameter workbench: 工作台模型
    static func all(workbench: WorkbenchModel) -> [PaletteCommand] {
        guard DemoLaunch.isActive else { return [] }
        let prefix = String(localized: "演示场景")
        return DemoScenarios.all.map { scenario in
            PaletteCommand(id: "demo-" + scenario.id, title: "\(prefix) · \(scenario.group) · \(scenario.title)", icon: "circle-play", shortcut: nil) {
                workbench.activeSession?.send("/" + scenario.commandName)
            }
        }
    }
}
