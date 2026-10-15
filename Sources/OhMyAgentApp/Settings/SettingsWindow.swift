// @author ygw
// 设置窗口(⌘,):15 个页面。Claude Code 自身的设置写回 settings.json 并热更新,客户端设置存 UserDefaults。

import IconKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 设置页。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts
    case agent, providers, permissions, tools, agentExtensions
    case editor, terminal
    case usage, privacy, advanced, diagnostics
    var id: String { rawValue }

    /// 侧栏分组(从上到下)。
    static let groups: [(title: String, pages: [SettingsPage])] = [
        ("客户端", [.general, .appearance, .shortcuts]),
        ("Agent", [.agent, .providers, .permissions, .tools, .agentExtensions]),
        ("工作台", [.editor, .terminal]),
        ("其他", [.usage, .privacy, .advanced, .diagnostics]),
    ]

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .appearance: return String(localized: "外观")
        case .shortcuts: return String(localized: "快捷键")
        case .agent: return String(localized: "Agent 与模型")
        case .providers: return String(localized: "模型提供商")
        case .permissions: return String(localized: "权限")
        case .tools: return String(localized: "工具与扩展")
        case .agentExtensions: return String(localized: "Agent 注册表")
        case .editor: return String(localized: "编辑器")
        case .terminal: return String(localized: "终端")
        case .usage: return String(localized: "用量与成本")
        case .privacy: return String(localized: "隐私与遥测")
        case .advanced: return String(localized: "高级")
        case .diagnostics: return String(localized: "诊断")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .agent: return "cpu"
        case .providers: return "server.rack"
        case .permissions: return "lock.shield"
        case .tools: return "puzzlepiece.extension"
        case .agentExtensions: return "square.stack.3d.up"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .usage: return "chart.bar"
        case .privacy: return "hand.raised"
        case .advanced: return "wrench.and.screwdriver"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// 设置路由:统一的深链入口(⇧⌘E → 工具与扩展、命令面板、托盘等都通过它切页)。
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    var page: SettingsPage = SettingsPage(rawValue: ProcessInfo.processInfo.environment["OMA_SETTINGS_PAGE"] ?? "") ?? .general
    var section: ExtensionSection = ExtensionSection(rawValue: ProcessInfo.processInfo.environment["OMA_SECTION"] ?? "") ?? .mcp

    /// 跳转到某页(可选带工具与扩展的分区)。
    func go(_ page: SettingsPage, section: ExtensionSection? = nil) {
        self.page = page
        if let section { self.section = section }
    }
}

/// 设置窗口所用的工作区:工作台当前选中的项目;主目录视为"无项目"(项目/本地层与用户层相同)。
enum SettingsContext {
    @MainActor
    static var workspace: URL? {
        guard let project = AppEnvironment.shared.workbench.selectedProject else { return nil }
        let url = project.url
        return url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path ? nil : url
    }
}

/// 设置整页(并入主窗口):左侧分组导航 + 搜索,右侧内容居中;「返回」回到工作台。
struct SettingsView: View {
    let workbench: WorkbenchModel
    @Bindable private var router = SettingsRouter.shared
    @State private var model = ClaudeSettingsModel(paths: ClaudePaths(workspace: SettingsContext.workspace))
    @State private var center = ConfigCenter(paths: ClaudePaths(workspace: SettingsContext.workspace))
    @State private var query = ""
    private let appearance = AppearanceModel.shared

    /// 需要全宽布局的页面(主从列表/大表格),其余页面内容限宽居中。
    private var usesFullWidth: Bool { [.tools, .agentExtensions, .diagnostics, .usage].contains(router.page) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
            Divider()
            VStack(spacing: 0) {
                if let error = model.lastError {
                    Label(error, om: "xmark.octagon.fill")
                        .font(OMFonts.small).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.red.opacity(0.1))
                }
                page
                    .id(appearance.fontRevision)
                    .frame(maxWidth: usesFullWidth ? .infinity : 720)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(router.page.title)
        .tint(appearance.accent.color)
        .onExitCommand { workbench.closeSettings() }
        .task {
            model.start()
            center.start()
            let tools = await Toolchain.shared.resolve()
            if let claude = tools.claudePath { center.setRunner(CLIRunner(executable: claude, environment: tools.environment)) }
        }
        .onDisappear { model.stop(); center.stop() }
    }

    /// 左侧导航:返回、搜索、分组页面列表。
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { workbench.closeSettings() } label: {
                    Label("返回", om: "arrow.left")
                        .font(OMFonts.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .help("返回工作台 (Esc)")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            HStack(spacing: 6) {
                Image.om("magnifyingglass", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索设置", text: $query)
                    .textFieldStyle(.plain)
                    .font(OMFonts.body)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(selection: $router.page) {
                ForEach(filteredGroups, id: \.title) { group in
                    Section(LocalizedStringKey(group.title)) {
                        ForEach(group.pages) { page in
                            Label(page.title, om: page.icon).tag(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
    }

    /// 按搜索词过滤后的分组(标题或分组名包含关键字)。
    private var filteredGroups: [(title: String, pages: [SettingsPage])] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return SettingsPage.groups }
        return SettingsPage.groups.compactMap { group in
            let pages = group.pages.filter { $0.title.localizedCaseInsensitiveContains(key) || group.title.localizedCaseInsensitiveContains(key) }
            return pages.isEmpty ? nil : (group.title, pages)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .general: GeneralPage()
        case .appearance: AppearancePage()
        case .agent: AgentModelPage(model: model)
        case .providers: ModelProvidersPage()
        case .permissions: PermissionsPage(model: model)
        case .tools: ToolsExtensionsPage(center: center, router: router)
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
