// @author ixxxxoooo
// 「自定义」页(对齐 Cursor 的 Customize):把 MCP、技能、子 Agent、Hooks、插件、记忆与指令合并成一页,
// 顶部搜索 + 类型筛选 + 浏览市场入口(暂未开发,置灰);选择具体类型后内嵌原有的管理页,宽度与「会话宽度」一致。
// 入口在主侧栏「新对话 / 自动化」下面,以预览标签的形式打开(`WorkbenchModel.customizeTabID`)。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 自定义页的类型筛选。
enum CustomizeFilter: String, CaseIterable, Identifiable {
    case plugins, mcp, skills, subagents, rules, hooks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .plugins: return String(localized: "插件")
        case .skills: return String(localized: "技能")
        case .subagents: return String(localized: "子 Agent")
        case .rules: return String(localized: "记忆与指令")
        case .mcp: return "MCP"
        case .hooks: return "Hooks"
        }
    }

    var icon: String {
        switch self {
        case .plugins: return "puzzlepiece.extension"
        case .skills: return "sparkles"
        case .subagents: return "person.2"
        case .rules: return "brain"
        case .mcp: return "server.rack"
        case .hooks: return "bolt.horizontal"
        }
    }

    /// 由旧的设置页映射过来(深链兼容)。
    /// - Parameter page: 设置页
    /// - Returns: 对应的筛选;非扩展类页面返回 nil
    static func from(page: SettingsPage) -> CustomizeFilter? {
        switch page {
        case .mcp: return .mcp
        case .skills: return .skills
        case .subagents: return .subagents
        case .hooks: return .hooks
        case .plugins: return .plugins
        case .memory: return .rules
        default: return nil
        }
    }

    /// 解析存储值,无法识别时回退「插件」。
    /// - Parameter raw: 原始字符串
    static func resolve(_ raw: String) -> CustomizeFilter { CustomizeFilter(rawValue: raw) ?? .plugins }
}

/// 自定义页。
struct CustomizePage: View {
    @Bindable var workbench: WorkbenchModel
    @State private var query = ""
    @State private var center = ConfigCenter(paths: ClaudePaths(workspace: SettingsContext.workspace))
    @AppStorage(ClientPrefs.Key.chatWidth) private var widthRaw = ChatWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.chatWidthCustom) private var widthCustom = ChatWidth.customDefault

    private var filter: CustomizeFilter { CustomizeFilter.resolve(workbench.customizeFilter) }

    /// 与「会话宽度」一致的内容最大宽度(外观 → 会话宽度):顶栏与各分类内容都按它限宽居中,左右边缘对齐。
    /// 会话时间线的正文宽度是 `contentWidth`(外侧另有边距);子页自带 28pt 横向内边距,这里补上,使可见内容宽度与会话一致。
    private var frameWidth: CGFloat { contentWidth + 56 }
    private var contentWidth: CGFloat { ChatWidth.resolve(raw: widthRaw, custom: widthCustom) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(maxWidth: frameWidth)
                .frame(maxWidth: .infinity)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: frameWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .task {
            center.start()
            let tools = await Toolchain.shared.resolve()
            if let claude = tools.claudePath {
                center.setRunner(CLIRunner(executable: claude, environment: tools.environment))
                if center.mcpHealth.isEmpty { await center.checkMCPHealth() }
            }
        }
        .onDisappear { center.stop() }
    }

    // MARK: 顶栏:搜索 + 市场入口(置灰) + 类型筛选

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ExtensionSearchField(placeholder: "搜索插件、技能、MCP…", text: $query)
                // 市场暂未开发:保持置灰
                Button("浏览市场") {}
                    .buttonStyle(.omSecondary)
                    .disabled(true)
                    .accessibilityLabel("浏览插件市场")
            }
            HStack(spacing: 6) {
                ForEach(CustomizeFilter.allCases) { item in
                    chip(item)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func chip(_ item: CustomizeFilter) -> some View {
        let selected = item == filter
        return Button { select(item) } label: {
            Text(verbatim: item.title)
                .font(OMFonts.small)
                .foregroundStyle(selected ? OMColors.primaryText : OMColors.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? OMColors.selectedFill : OMColors.subtleFill, in: OMPillShape())
                .overlay(OMPillShape().strokeBorder(selected ? OMColors.accent.opacity(0.5) : OMColors.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ item: CustomizeFilter) {
        omWithAnimation(.snappy(duration: 0.15)) { workbench.customizeFilter = item.rawValue }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .mcp: MCPSettingsPage(center: center, query: query)
        case .skills: SkillsSettingsPage(center: center, kind: .skill, query: query)
        case .subagents: SkillsSettingsPage(center: center, kind: .agent, query: query)
        case .hooks: HooksSettingsPage(center: center, query: query)
        case .plugins: PluginsSettingsPage(center: center, query: query)
        case .rules: MemorySettingsPage(center: center, query: query)
        }
    }
}
