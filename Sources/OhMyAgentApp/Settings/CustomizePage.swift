// @author ixxxxoooo
// 「自定义」页(对齐 Cursor 的 Customize):把 MCP、技能、子 Agent、Hooks、插件、记忆与指令合并成一页,
// 顶部搜索 + 类型筛选,「全部」视图按「需要处理 / 已连接」分组列出;选择具体类型后内嵌原有的管理页。
// 入口在主侧栏「新对话 / 自动化」下面,以预览标签的形式打开(`WorkbenchModel.customizeTabID`)。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 自定义页的类型筛选。
enum CustomizeFilter: String, CaseIterable, Identifiable {
    case all, plugins, skills, subagents, rules, mcp, hooks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "全部")
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
        case .all: return "list"
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

    /// 解析存储值,无法识别时回退「全部」。
    /// - Parameter raw: 原始字符串
    static func resolve(_ raw: String) -> CustomizeFilter { CustomizeFilter(rawValue: raw) ?? .all }
}

/// 「全部」视图里的一行(跨类型的统一条目)。
struct CustomizeItem: Identifiable {
    enum Status { case attention(String), connected, disabled }
    let id: String
    let kind: CustomizeFilter
    let icon: String
    let title: String
    let subtitle: String
    /// 来源标签(如「用户」「项目」「插件 x」)
    let source: String
    let status: Status

    var needsAttention: Bool { if case .attention = status { return true } else { return false } }
}

/// 自定义页。
struct CustomizePage: View {
    @Bindable var workbench: WorkbenchModel
    @State private var center = ConfigCenter(paths: ClaudePaths(workspace: SettingsContext.workspace))
    @State private var query = ""
    @AppStorage(ClientPrefs.Key.settingsWidth) private var widthRaw = SettingsContentWidth.standard.rawValue
    @AppStorage(ClientPrefs.Key.settingsWidthCustom) private var widthCustom = SettingsContentWidth.customDefault

    private var filter: CustomizeFilter { CustomizeFilter.resolve(workbench.customizeFilter) }

    /// 与设置页共用的内容最大宽度(外观 → 设置页宽度):顶栏与各分类内容都按它限宽居中,左右边缘对齐。
    private var contentWidth: CGFloat { SettingsContentWidth.resolve(raw: widthRaw, custom: widthCustom) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: contentWidth)
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

    // MARK: 顶栏:搜索 + 市场入口 + 类型筛选

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ExtensionSearchField(placeholder: "搜索插件、技能、MCP…", text: $query)
                Button("浏览市场") { select(.plugins) }
                    .buttonStyle(.omPrimary)
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
        case .all: overview
        case .mcp: MCPSettingsPage(center: center)
        case .skills: SkillsSettingsPage(center: center, kind: .skill)
        case .subagents:
            VStack(spacing: 0) {
                builtinAgents
                SkillsSettingsPage(center: center, kind: .agent)
            }
        case .hooks: HooksSettingsPage(center: center)
        case .plugins: PluginsSettingsPage(center: center)
        case .rules: MemorySettingsPage(center: center)
        }
    }

    /// 内置子 Agent(Claude Code 自带,无需配置):Explore 用于快速只读检索,输入框 `/explore` 是快捷入口。
    private var builtinAgents: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtensionSectionLabel(title: String(localized: "内置"), count: 1)
            ExtensionCardList {
                ExtensionRow(icon: "search", title: "Explore",
                             subtitle: String(localized: "快速、只读地检索代码库并回答问题;配合 search_code 索引搜索。在输入框用 /explore 提问。")) {
                    OMTag(String(localized: "内置"))
                } trailing: {
                    OMTag("/explore", tint: OMColors.accent)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    /// 「全部」视图:需要处理 + 已连接,两组卡片列表。
    private var overview: some View {
        let items = filteredItems
        let attention = items.filter(\.needsAttention)
        let rest = items.filter { !$0.needsAttention }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ExtensionBanners(center: center)
                if items.isEmpty {
                    ExtensionEmptyCard(icon: "puzzlepiece.extension", title: String(localized: "没有匹配的内容"),
                                       message: String(localized: "换个关键词,或到「插件」里浏览市场添加。"))
                }
                if !attention.isEmpty {
                    ExtensionSectionLabel(title: String(localized: "需要处理"), count: attention.count)
                    ExtensionCardList { rows(attention) }
                }
                if !rest.isEmpty {
                    ExtensionSectionLabel(title: String(localized: "已连接"), count: rest.count)
                    ExtensionCardList { rows(rest) }
                }
                newMenu
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rows(_ list: [CustomizeItem]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
            if index > 0 { ExtensionRowDivider() }
            ExtensionRow(icon: item.icon, tint: tint(item.status), title: item.title, subtitle: item.subtitle,
                         dimmed: { if case .disabled = item.status { return true } else { return false } }(),
                         onTap: { select(item.kind) }) {
                OMTag(item.kind.title, tint: OMColors.accent)
                if !item.source.isEmpty { OMTag(item.source) }
            } trailing: {
                statusView(item.status)
            }
        }
    }

    /// 底部「新建」快捷入口:跳到对应类型页(新建动作在各页右上角)。
    private var newMenu: some View {
        HStack(spacing: 8) {
            ForEach([CustomizeFilter.mcp, .skills, .subagents, .hooks], id: \.self) { item in
                Button {
                    select(item)
                } label: {
                    Label(String(localized: "管理 \(item.title)"), om: item.icon)
                }
                .buttonStyle(.omSecondary)
            }
        }
        .padding(.top, 4)
    }

    private func tint(_ status: CustomizeItem.Status) -> Color {
        if case .attention = status { return OMColors.warning }
        return OMColors.accent
    }

    @ViewBuilder
    private func statusView(_ status: CustomizeItem.Status) -> some View {
        switch status {
        case .attention(let text):
            HStack(spacing: 6) {
                OMStatusDot(.warning)
                Text(verbatim: text).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
            }
        case .connected:
            OMStatusDot(.success)
        case .disabled:
            Text("已停用").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
        }
    }

    // MARK: 数据

    /// 经搜索词过滤的统一条目。
    private var filteredItems: [CustomizeItem] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = Self.items(from: center.snapshot, health: center.mcpHealth)
        guard !key.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(key) || $0.subtitle.localizedCaseInsensitiveContains(key)
                || $0.source.localizedCaseInsensitiveContains(key) || $0.kind.title.localizedCaseInsensitiveContains(key)
        }
    }

    /// 把配置快照归并成统一条目(纯函数,便于测试)。
    /// - Parameters:
    ///   - snapshot: 配置快照
    ///   - health: MCP 连接状态(`claude mcp list` 的结果,可为空)
    /// - Returns: 条目列表(MCP、插件、技能与命令、子 Agent、Hooks、记忆)
    static func items(from snapshot: ConfigSnapshot, health: [String: MCPHealthStatus]) -> [CustomizeItem] {
        var result: [CustomizeItem] = []
        for entry in snapshot.mcp where entry.overriddenBy == nil {
            let name = entry.config.name
            let status: CustomizeItem.Status
            if entry.isDisabled {
                status = .disabled
            } else if entry.needsApproval {
                status = .attention(String(localized: "待批准"))
            } else if let state = health[name]?.state {
                switch state {
                case .needsAuth: status = .attention(String(localized: "需要认证"))
                case .failed: status = .attention(String(localized: "连接失败"))
                case .connected, .unknown: status = .connected
                }
            } else {
                status = .connected
            }
            let subtitle = entry.config.url.isEmpty ? ([entry.config.command] + entry.config.args).joined(separator: " ") : entry.config.url
            result.append(CustomizeItem(id: "mcp:\(entry.id)", kind: .mcp, icon: "server.rack", title: name, subtitle: subtitle,
                                        source: entry.scope.displayName, status: status))
        }
        for plugin in snapshot.plugins {
            result.append(CustomizeItem(id: "plugin:\(plugin.id)", kind: .plugins, icon: "puzzlepiece.extension", title: plugin.name,
                                        subtitle: plugin.description, source: plugin.marketplace, status: plugin.isEnabled ? .connected : .disabled))
        }
        for item in snapshot.skills where item.overriddenBy == nil {
            result.append(CustomizeItem(id: "skill:\(item.id)", kind: .skills, icon: item.kind == .command ? "terminal" : "sparkles", title: item.name,
                                        subtitle: item.description, source: item.source.displayName, status: .connected))
        }
        for item in snapshot.agents where item.overriddenBy == nil {
            result.append(CustomizeItem(id: "agent:\(item.id)", kind: .subagents, icon: "person.2", title: item.name,
                                        subtitle: item.description, source: item.source.displayName, status: .connected))
        }
        for hook in snapshot.hooks {
            let subtitle = hook.matcher.isEmpty ? hook.event : "\(hook.event) · \(hook.matcher)"
            result.append(CustomizeItem(id: "hook:\(hook.id)", kind: .hooks, icon: "bolt.horizontal", title: hook.event,
                                        subtitle: subtitle, source: hook.origin.displayName, status: .connected))
        }
        for file in snapshot.memory where file.exists {
            result.append(CustomizeItem(id: "memory:\(file.id)", kind: .rules, icon: "brain", title: file.title,
                                        subtitle: file.url.path, source: "", status: .connected))
        }
        return result
    }
}
