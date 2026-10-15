// @author ygw
// 设置页:Agent 扩展(Agent 注册表、OhMyAgent Bridge、Agent-as-MCP)。M7 完成真实功能前先展示现状。

import ChatKit
import DesignSystem
import SwiftUI

/// Agent 扩展。
struct AgentExtensionsPage: View {
    var body: some View {
        SettingsForm {
            Section("当前 Agent") {
                let descriptor = Toolchain.defaultDescriptor()
                LabeledContent("名称", value: descriptor.name)
                LabeledContent("类型", value: descriptor.kind.rawValue)
            }
            Section {
                Note("Agent 注册表、OhMyAgent Bridge 与 Agent-as-MCP 将在 M7 提供。")
            }
        }
    }
}
