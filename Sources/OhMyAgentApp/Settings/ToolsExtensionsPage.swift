// @author ygw
// 设置页「工具与扩展」:MCP / Skills / 子 Agent / Hooks / 插件 / 记忆与指令的唯一入口(取代原独立的「扩展管理」窗口)。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 工具与扩展的分区。
enum ExtensionSection: String, CaseIterable, Identifiable {
    case mcp, skills, agents, hooks, plugins, memory
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mcp: return "MCP 服务器"
        case .skills: return "Skills 与命令"
        case .agents: return "子 Agent"
        case .hooks: return "Hooks"
        case .plugins: return "插件"
        case .memory: return "记忆与指令"
        }
    }

    /// 分段控件使用的短标题。
    var shortTitle: String {
        switch self {
        case .mcp: return "MCP"
        case .skills: return "Skills"
        case .agents: return "子 Agent"
        case .hooks: return "Hooks"
        case .plugins: return "插件"
        case .memory: return "记忆"
        }
    }

    var icon: String {
        switch self {
        case .mcp: return "server.rack"
        case .skills: return "sparkles"
        case .agents: return "person.2"
        case .hooks: return "bolt.horizontal"
        case .plugins: return "puzzlepiece.extension"
        case .memory: return "brain"
        }
    }
}

/// 工具与扩展页:顶部分段选择分区,下方是对应的管理视图。
struct ToolsExtensionsPage: View {
    let center: ConfigCenter
    @Bindable var router: SettingsRouter

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $router.section) {
                ForEach(ExtensionSection.allCases) { section in
                    Text(count(section) > 0 ? "\(section.shortTitle) \(count(section))" : section.shortTitle).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            StatusBanner(center: center)
            if let error = center.snapshot.errors[errorKey(router.section)] {
                Label(error, om: "exclamationmark.triangle.fill")
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            switch router.section {
            case .mcp: MCPManagerView(center: center)
            case .skills: MarkdownItemManagerView(center: center, kind: .skill)
            case .agents: MarkdownItemManagerView(center: center, kind: .agent)
            case .hooks: HooksManagerView(center: center)
            case .plugins: PluginsManagerView(center: center)
            case .memory: MemoryManagerView(center: center)
            }
        }
    }

    private func count(_ section: ExtensionSection) -> Int {
        switch section {
        case .mcp: return center.snapshot.mcp.count
        case .skills: return center.snapshot.skills.count
        case .agents: return center.snapshot.agents.count
        case .hooks: return center.snapshot.hooks.count
        case .plugins: return center.snapshot.plugins.count
        case .memory: return center.snapshot.memory.filter(\.exists).count
        }
    }

    private func errorKey(_ section: ExtensionSection) -> String {
        switch section {
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        default: return "-"
        }
    }
}
