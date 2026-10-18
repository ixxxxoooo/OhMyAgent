// @author ixxxxoooo
// 设置 → 浏览器:Agent 操作内置浏览器的审批,以及清除当前项目的浏览数据。

import ChatKit
import DesignSystem
import SwiftUI

struct BrowserPage: View {
    @State private var cleared = false

    var body: some View {
        SettingsScroll {
            ToolApprovalCard(domain: .browser)
            SettingsCard("浏览数据") {
                SettingsRow("清除当前项目的浏览数据", detail: "删除这个项目浏览器里的 Cookie、缓存与本地存储(包括登录状态)。同一项目里用户与 Agent 共用同一份数据,不同项目互不可见。") {
                    Button(cleared ? "已清除" : "清除") {
                        guard let workspace = AppEnvironment.shared.workbench.selectedProjectID else { return }
                        Task {
                            await BrowserController.shared.clearData(workspace: workspace)
                            cleared = true
                        }
                    }
                    .buttonStyle(.omSecondary)
                    .disabled(AppEnvironment.shared.workbench.selectedProjectID == nil)
                }
                Note("浏览器只允许 http/https 页面;file、javascript 等协议会被拦截。Agent 通过 browser_navigate / snapshot / click(含双击、右键)/ hover / type / scroll / back / forward / reload / screenshot / console / network 等工具操作它。在消息里写 @browser 可以明确要求 Agent 用它,并复用本机已在运行的开发服务器。在浏览器标签页工具栏点「选择页面元素」,可以把页面上的某个元素连同截图发进输入框。").footnote()
            }
        }
    }
}
