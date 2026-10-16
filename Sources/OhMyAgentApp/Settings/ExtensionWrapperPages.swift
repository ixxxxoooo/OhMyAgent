// @author ixxxxoooo
// 插件、记忆与指令设置页:统一页头 + 卡片容器,内容沿用原管理视图(带自己的工具栏与分栏)。

import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI

/// 插件设置页。
struct PluginsSettingsPage: View {
    let center: ConfigCenter

    var body: some View {
        ExtensionFixedPage(
            center: center, icon: "puzzlepiece.extension", title: String(localized: "插件"),
            subtitle: String(localized: "安装、启停与更新 Claude Code 插件,插件可携带技能、子 Agent、Hooks 与 MCP 服务器。需要本机已安装 claude 命令。")
        ) {
            Button { center.reload() } label: { Image.om("arrow.clockwise") }
                .help("重新读取配置")
                .accessibilityLabel("刷新")
        } content: {
            PluginsManagerView(center: center)
        }
    }
}

/// 记忆与指令设置页。
struct MemorySettingsPage: View {
    let center: ConfigCenter

    var body: some View {
        ExtensionFixedPage(
            center: center, icon: "brain", title: String(localized: "记忆与指令"),
            subtitle: String(localized: "管理 CLAUDE.md 与 rules 规则文件,决定 Claude 在用户、项目层面默认遵循的指令。")
        ) {
            Button { center.reload() } label: { Image.om("arrow.clockwise") }
                .help("重新读取配置")
                .accessibilityLabel("刷新")
        } content: {
            MemoryManagerView(center: center)
        }
    }
}
