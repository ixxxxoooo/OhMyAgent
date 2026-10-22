// @author ixxxxoooo
// 设置页的侧栏与页面宿主。拆成独立视图是为了切页流畅:
// 只有侧栏(和不可见的路由跟随器)读取 `SettingsRouter.page`,点击时只重算侧栏,高亮立即画出;
// 页面宿主按页面 ID 判等,父视图重算时保活中的页面不会重跑 body。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 设置页左侧导航:返回、搜索、分组页面列表。
struct SettingsSidebar: View {
    let workbench: WorkbenchModel
    /// 顶部为红绿灯预留的高度(嵌在 IDE 窗口里时自带标题栏,传 0)
    var topInset: CGFloat = TitlebarMetrics.height
    /// 点「返回」的动作
    var onClose: () -> Void
    @Bindable private var router = SettingsRouter.shared
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            // 第一行留给红绿灯(整行可拖动窗口);「返回」放在红绿灯下面一行,不与红绿灯并排
            if topInset > 0 {
                Color.clear
                    .frame(height: topInset)
                    .background(WindowDragArea())
            }
            HStack {
                Button { onClose() } label: {
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredGroups, id: \.title) { group in
                        Text(LocalizedStringKey(group.title))
                            .font(OMFonts.small)
                            .foregroundStyle(OMColors.tertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(group.pages) { page in
                            SettingsSidebarRow(page: page, selected: router.page == page) { router.page = page }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
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
}

/// 设置页左栏的一行:选中态取主题 `selectedFill`,不用系统列表的强调蓝(窗口激活/失活时颜色不再变化)。
private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(page.title, om: page.icon)
                .font(OMFonts.body)
                .foregroundStyle(OMColors.primaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: OMRadius.control, style: .continuous)
                        .fill(selected ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 不可见的路由跟随器:选中页变化时回调(含深链等外部跳转),让父视图不必在 body 里读取 `router.page`。
struct SettingsRouteFollower: View {
    /// 选中页变化时调用,参数为新页面
    let onChange: (SettingsPage) -> Void
    private let router = SettingsRouter.shared

    var body: some View {
        Color.clear.onChange(of: router.page) { _, next in onChange(next) }
    }
}

/// 在本轮 RunLoop 的渲染提交之后执行一次。
/// `main.async` 会在同一轮、提交之前执行(与触发它的改动挤进同一帧);这里用排在
/// Core Animation 提交观察者(order 2000000)之后的一次性观察者,保证先上屏再执行。
@MainActor
enum RunLoopAfterCommit {
    /// - Parameter block: 提交后要执行的操作
    static func perform(_ block: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_100_000) { _, _ in
            MainActor.assumeIsolated { block() }
            // 观察者里改的状态需要下一轮 RunLoop 处理,唤醒以免主循环直接休眠
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// 单个设置页的宿主:按页面 ID 判等(配合 `.equatable()`),父视图重算时不重建页面内容。
/// 所引用的模型在设置视图生命周期内不变,所以只比较页面即可。
struct SettingsPageHost: View, Equatable {
    let page: SettingsPage
    let workbench: WorkbenchModel
    let model: ClaudeSettingsModel
    let center: ConfigCenter

    /// - Returns: 两个宿主是否展示同一页面
    nonisolated static func == (lhs: SettingsPageHost, rhs: SettingsPageHost) -> Bool {
        lhs.page == rhs.page
    }

    var body: some View {
        switch page {
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
        case .about: AboutPage()
        }
    }
}
