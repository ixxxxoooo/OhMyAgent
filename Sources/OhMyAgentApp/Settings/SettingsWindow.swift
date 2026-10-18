// @author ixxxxoooo
// 设置窗口(⌘,):18 个页面。Claude Code 自身的设置写回 settings.json 并热更新,客户端设置存 UserDefaults。

import IconKit
import ChatKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI
import WorkbenchKit

/// 设置页。
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts
    case agent, providers, modelMapping, prompts, network, permissions, trust, agentExtensions
    case mcp, skills, subagents, hooks, plugins, memory
    case editor, terminal, browser, sourceControl, codeIntelligence
    case usage, privacy, advanced, diagnostics
    var id: String { rawValue }

    /// 设置搜索的附加关键词(页标题之外还能搜到的词)。
    var keywords: [String] {
        switch self {
        case .mcp: return ["mcp", "model context protocol", "服务器", "工具", "server", "tools", "claude mcp"]
        case .skills: return ["skill", "skills", "技能", "命令", "斜杠", "command", "slash", "SKILL.md"]
        case .subagents: return ["agent", "subagent", "子代理", "子 agent", "代理", "agents"]
        case .hooks: return ["hook", "hooks", "钩子", "生命周期", "PreToolUse", "PostToolUse"]
        case .plugins: return ["plugin", "plugins", "插件", "市场", "marketplace", "扩展"]
        case .memory: return ["memory", "记忆", "claude.md", "指令", "rules", "规则", "instructions"]
        case .providers: return ["provider", "api", "密钥", "key", "openai", "anthropic"]
        case .agentExtensions: return ["acp", "registry", "codex", "gemini", "pi", "opencode", "注册表"]
        case .shortcuts: return ["快捷键", "shortcut", "keybinding"]
        case .sourceControl: return ["git", "提交", "commit", "署名", "co-authored-by", "提交说明", "scm", "工作树", "worktree"]
        case .browser: return ["browser", "浏览器", "网页", "webview", "cookie", "审批", "localhost"]
        case .codeIntelligence: return ["lsp", "语言服务器", "诊断", "补全", "忽略", "ignore", "glob", "索引", "language server"]
        default: return []
        }
    }

    /// 由环境变量/旧深链的名称解析设置页(兼容旧的 `tools` 页名)。
    /// - Parameter name: 页面 rawValue 或旧名称
    static func resolve(_ name: String) -> SettingsPage? {
        if name == "tools" { return .mcp }
        return SettingsPage(rawValue: name)
    }

    /// 侧栏分组(从上到下)。
    static let groups: [(title: String, pages: [SettingsPage])] = [
        (String(localized: "客户端"), [.general, .appearance, .shortcuts]),
        ("Agent", [.agent, .providers, .modelMapping, .prompts, .network, .permissions, .trust, .agentExtensions]),
        (String(localized: "工作台"), [.editor, .terminal, .browser, .sourceControl, .codeIntelligence]),
        (String(localized: "其他"), [.usage, .privacy, .advanced, .diagnostics]),
    ]

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .appearance: return String(localized: "外观")
        case .shortcuts: return String(localized: "快捷键")
        case .agent: return String(localized: "Agent 与模型")
        case .providers: return String(localized: "模型提供商")
        case .modelMapping: return String(localized: "Claude Code 模型映射")
        case .prompts: return String(localized: "提示词")
        case .network: return String(localized: "网络")
        case .permissions: return String(localized: "权限")
        case .trust: return String(localized: "项目信任")
        case .agentExtensions: return String(localized: "Agent 注册表")
        case .mcp: return "MCP"
        case .skills: return String(localized: "技能")
        case .subagents: return String(localized: "子 Agent")
        case .hooks: return "Hooks"
        case .plugins: return String(localized: "插件")
        case .memory: return String(localized: "规则")
        case .editor: return String(localized: "编辑器")
        case .terminal: return String(localized: "终端")
        case .sourceControl: return String(localized: "源代码管理")
        case .browser: return String(localized: "浏览器")
        case .codeIntelligence: return String(localized: "代码智能")
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
        case .modelMapping: return "arrow.triangle.swap"
        case .prompts: return "doc.text"
        case .network: return "network"
        case .permissions: return "lock.shield"
        case .trust: return "shield-check"
        case .agentExtensions: return "square.stack.3d.up"
        case .mcp: return "brand.mcp"
        case .skills: return "sparkles"
        case .subagents: return "person.2"
        case .hooks: return "bolt.horizontal"
        case .plugins: return "puzzlepiece.extension"
        case .memory: return "brain"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .sourceControl: return "git-branch"
        case .browser: return "globe"
        case .codeIntelligence: return "braces"
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

    var page: SettingsPage = SettingsRouter.initialPage()

    /// 启动页:`OMA_SETTINGS_PAGE`;旧的 `OMA_SECTION`(工具与扩展分区)映射到对应的独立页。
    nonisolated static func initialPage() -> SettingsPage {
        let env = ProcessInfo.processInfo.environment
        if let section = env["OMA_SECTION"].flatMap(ExtensionSection.init(rawValue:)) { return section.page }
        return env["OMA_SETTINGS_PAGE"].flatMap(SettingsPage.resolve) ?? .general
    }

    /// 跳转到某页。
    func go(_ page: SettingsPage) { self.page = page }

    /// 跳转到某个扩展分区(MCP/技能/子 Agent/Hooks/插件/记忆)对应的独立页。
    func go(extension section: ExtensionSection) { page = section.page }
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

    @AppStorage(ClientPrefs.Key.settingsWidth) private var widthRaw = SettingsContentWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.settingsWidthCustom) private var widthCustom = SettingsContentWidth.customDefault

    /// 所有设置页统一的内容最大宽度(外观页可配置)。
    private var contentWidth: CGFloat { SettingsContentWidth.resolve(raw: widthRaw, custom: widthCustom) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: CGFloat(PanelMetrics.clamp(workbench.layout.leftWidth, side: .left)))
            Divider()
            VStack(spacing: 0) {
                // 顶部标题栏高度的可拖动区域:内容不会顶到红绿灯所在行
                Color.clear.frame(height: TitlebarMetrics.height).background(WindowDragArea())
                if let error = model.lastError {
                    Label(error, om: "xmark.octagon.fill")
                        .font(OMFonts.small).foregroundStyle(OMColors.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(OMColors.danger.opacity(0.1))
                }
                page
                    .id(router.page)
                    .frame(maxWidth: contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OMColors.surface)
            }
            .background(OMColors.surface)
        }
        .background(OMColors.surface)
        // 无标题栏窗口:内容铺满到窗口顶部,由侧栏/内容区各自预留标题栏高度,避免系统安全区叠加出多余留白
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(router.page.title)
        .tint(appearance.tint)
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
            // 第一行留给红绿灯(整行可拖动窗口);「返回」放在红绿灯下面一行,不与红绿灯并排
            Color.clear
                .frame(height: TitlebarMetrics.height)
                .background(WindowDragArea())
            HStack {
                Button { workbench.closeSettings() } label: {
                    Label("返回", om: "arrow.left")
                        .font(OMFonts.body)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(OMColors.secondaryText)
                .omTooltip("返回工作台 (Esc)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            HStack(spacing: 6) {
                Image.om("magnifyingglass", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("搜索设置", text: $query)
                    .textFieldStyle(.plain)
                    .font(OMFonts.body)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: OMRadius.control).fill(OMColors.hoverFill))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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
        .background(SidebarBackground())
    }

    /// 按搜索词过滤后的分组(标题或分组名包含关键字)。
    private var filteredGroups: [(title: String, pages: [SettingsPage])] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return SettingsPage.groups }
        return SettingsPage.groups.compactMap { group in
            let pages = group.pages.filter { page in
                page.title.localizedCaseInsensitiveContains(key) || group.title.localizedCaseInsensitiveContains(key)
                    || page.keywords.contains { $0.localizedCaseInsensitiveContains(key) }
            }
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
        case .modelMapping: ModelMappingPage()
        case .prompts: PromptsPage()
        case .network: NetworkPage()
        case .permissions: PermissionsPage(model: model)
        case .trust: ProjectTrustPage(workbench: workbench)
        case .mcp: MCPSettingsPage(center: center)
        case .skills: SkillsSettingsPage(center: center, kind: .skill)
        case .subagents: SkillsSettingsPage(center: center, kind: .agent)
        case .hooks: HooksSettingsPage(center: center)
        case .plugins: PluginsSettingsPage(center: center)
        case .memory: MemorySettingsPage(center: center)
        case .editor: EditorPage()
        case .terminal: TerminalPage()
        case .sourceControl: SourceControlPage()
        case .browser: BrowserPage()
        case .codeIntelligence: CodeIntelligencePage()
        case .shortcuts: ShortcutsPage()
        case .usage: UsagePage(paths: model.paths)
        case .agentExtensions: AgentExtensionsPage()
        case .privacy: PrivacyPage(model: model)
        case .advanced: AdvancedPage(model: model)
        case .diagnostics: DiagnosticsPage(center: center)
        }
    }
}
