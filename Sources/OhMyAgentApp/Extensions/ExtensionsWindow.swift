// @author ygw
// 扩展管理窗口:MCP / Skills / 子 Agent / Hooks / 插件 / 记忆。每个窗口绑定一个工作区,监听配置文件变化自动刷新。

import AgentHost
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 管理页分区。
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

/// 扩展管理窗口。
struct ExtensionsWindow: View {
    let workspace: URL
    @State private var center: ConfigCenter
    @State private var selection: ExtensionSection? = ExtensionSection(rawValue: ProcessInfo.processInfo.environment["OMA_SECTION"] ?? "") ?? .mcp

    init(workspace: URL) {
        self.workspace = workspace
        _center = State(initialValue: ConfigCenter(paths: ClaudePaths(workspace: workspace)))
    }

    var body: some View {
        NavigationSplitView {
            List(ExtensionSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(count(section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner(center: center)
                if let error = center.snapshot.errors[errorKey(selection)] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                switch selection ?? .mcp {
                case .mcp: MCPManagerView(center: center)
                case .skills: MarkdownItemManagerView(center: center, kind: .skill)
                case .agents: MarkdownItemManagerView(center: center, kind: .agent)
                case .hooks: HooksManagerView(center: center)
                case .plugins: PluginsManagerView(center: center)
                case .memory: MemoryManagerView(center: center)
                }
            }
        }
        .navigationTitle("扩展管理")
        .navigationSubtitle(workspace.abbreviatingHome)
        .frame(minWidth: 900, minHeight: 560)
        .task {
            center.start()
            let tools = await Toolchain.shared.resolve()
            if let claude = tools.claudePath { center.setRunner(CLIRunner(executable: claude, environment: tools.environment)) }
        }
        .onDisappear { center.stop() }
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

    private func errorKey(_ section: ExtensionSection?) -> String {
        switch section ?? .mcp {
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        default: return "-"
        }
    }
}
