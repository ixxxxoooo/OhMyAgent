// @author ygw
// 设置窗口(⌘,):15 个页面。Claude Code 自身的设置写回 settings.json 并热更新,客户端设置存 UserDefaults。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 设置页。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, agent, permissions, mcp, extensions, memory, editor
    case terminal, shortcuts, usage, agentExtensions, privacy, advanced, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .agent: return "Agent 与模型"
        case .permissions: return "权限"
        case .mcp: return "MCP"
        case .extensions: return "扩展(Skills 等)"
        case .memory: return "记忆与指令"
        case .editor: return "编辑器"
        case .terminal: return "终端"
        case .shortcuts: return "快捷键"
        case .usage: return "用量与成本"
        case .agentExtensions: return "Agent 扩展"
        case .privacy: return "隐私与遥测"
        case .advanced: return "高级"
        case .diagnostics: return "诊断"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .agent: return "cpu"
        case .permissions: return "lock.shield"
        case .mcp: return "server.rack"
        case .extensions: return "puzzlepiece.extension"
        case .memory: return "brain"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .shortcuts: return "keyboard"
        case .usage: return "chart.bar"
        case .agentExtensions: return "square.stack.3d.up"
        case .privacy: return "hand.raised"
        case .advanced: return "wrench.and.screwdriver"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// 设置窗口所用的工作区:最近使用的目录;主目录视为"无工作区"(项目/本地层与用户层相同)。
enum SettingsContext {
    static var workspace: URL? {
        let url = WorkspaceStore.defaultWorkspace
        return url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path ? nil : url
    }
}

/// 设置窗口根视图。
struct SettingsView: View {
    @State private var selection: SettingsPage = SettingsPage(rawValue: ProcessInfo.processInfo.environment["OMA_SETTINGS_PAGE"] ?? "") ?? .general
    @State private var model = ClaudeSettingsModel(paths: ClaudePaths(workspace: SettingsContext.workspace))
    @State private var center = ConfigCenter(paths: ClaudePaths(workspace: SettingsContext.workspace))
    private let appearance = AppearanceModel.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(OMFonts.small).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.red.opacity(0.1))
                }
                page.id(appearance.fontRevision)
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 860, idealWidth: 960, minHeight: 560, idealHeight: 660)
        .tint(appearance.accent.color)
        .task {
            model.start()
            center.start()
            let tools = await Toolchain.shared.resolve()
            if let claude = tools.claudePath { center.setRunner(CLIRunner(executable: claude, environment: tools.environment)) }
        }
        .onDisappear { model.stop(); center.stop() }
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .general: GeneralPage()
        case .appearance: AppearancePage()
        case .agent: AgentModelPage(model: model)
        case .permissions: PermissionsPage(model: model)
        case .mcp: MCPManagerView(center: center)
        case .extensions: ExtensionsBundlePage(center: center)
        case .memory: MemoryManagerView(center: center)
        case .editor: EditorPage()
        case .terminal: TerminalPage()
        case .shortcuts: ShortcutsPage()
        case .usage: UsagePage(paths: model.paths)
        case .agentExtensions: AgentExtensionsPage()
        case .privacy: PrivacyPage(model: model)
        case .advanced: AdvancedPage(model: model)
        case .diagnostics: DiagnosticsPage(center: center)
        }
    }
}
