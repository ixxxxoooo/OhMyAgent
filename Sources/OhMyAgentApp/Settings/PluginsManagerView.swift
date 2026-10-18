// @author ixxxxoooo
// 插件管理:已安装列表(启停/更新/卸载)、市场管理与安装。变更全部委托官方 `claude plugin` CLI。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 插件管理页。
struct PluginsManagerView: View {
    let center: ConfigCenter
    /// 顶栏搜索词(由自定义页传入),过滤已安装列表
    var query = ""
    @State private var installName = ""
    @State private var marketplaceSource = ""
    @State private var installScope = "user"
    @State private var pendingInstall: String?
    @State private var pendingUninstall: InstalledPlugin?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !center.canRunCLI {
                Label("没有找到 claude 命令行工具,插件的安装/启停/卸载不可用(下方列表仍可只读查看)。", om: "exclamationmark.triangle")
                    .font(OMFonts.small).foregroundStyle(OMColors.warning)
            }
            installSection
            installedSection
            marketplaceSection
        }
        .confirmationDialog("安装插件前请确认", isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }), presenting: pendingInstall) { name in
            Button("安装 \(name)") {
                Task { await center.runCLI(PluginStore.installArguments(name, scope: installScope), message: String(localized: "正在安装 \(name)…"), notice: String(localized: "已安装 \(name)")) }
                installName = ""
            }
        } message: { name in
            Text("插件可以在你的电脑上运行代码(命令、MCP 服务器、Hook)。请只安装信任来源的插件。\n插件:\(name)  作用域:\(installScope)")
        }
        .confirmationDialog("卸载插件?", isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }), presenting: pendingUninstall) { plugin in
            Button("卸载 \(plugin.name)", role: .destructive) {
                Task { await center.runCLI(PluginStore.uninstallArguments(plugin.pluginID, scope: plugin.scope), message: String(localized: "正在卸载…"), notice: String(localized: "已卸载 \(plugin.name)")) }
            }
        }
    }

    /// CLI 不可用或正在执行时,变更类按钮不可点。
    private var actionsDisabled: Bool { center.isBusy || !center.canRunCLI }

    // MARK: 安装

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtensionSectionLabel(title: String(localized: "安装插件"))
            HStack(spacing: 8) {
                TextField("plugin@marketplace", text: $installName).textFieldStyle(.omField).font(OMFonts.mono)
                OMCompactSegmented(
                    options: [("user", String(localized: "用户")), ("project", String(localized: "项目")), ("local", String(localized: "本地"))],
                    selection: $installScope, accessibilityName: String(localized: "安装作用域"))
                Button("安装…") {
                    do { try PluginStore.validateArgument(installName); pendingInstall = installName.trimmingCharacters(in: .whitespaces) }
                    catch { center.lastError = error.localizedDescription }
                }
                .buttonStyle(.omPrimary)
                .disabled(installName.isEmpty || actionsDisabled)
            }
        }
    }

    // MARK: 已安装

    private var installedPlugins: [InstalledPlugin] {
        guard !query.isEmpty else { return center.snapshot.plugins }
        return center.snapshot.plugins.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
                || $0.marketplace.localizedCaseInsensitiveContains(query)
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtensionSectionLabel(title: String(localized: "已安装"), count: installedPlugins.count)
            if installedPlugins.isEmpty {
                ExtensionEmptyCard(icon: "puzzlepiece.extension", title: String(localized: "还没有安装插件"),
                                   message: String(localized: "在上方输入 plugin@marketplace 安装,或先添加一个插件市场。"))
            } else {
                ExtensionCardList {
                    ForEach(Array(installedPlugins.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { ExtensionRowDivider() }
                        pluginRow(plugin)
                    }
                }
            }
        }
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        ExtensionRow(
            icon: "puzzlepiece.extension", title: plugin.name, subtitle: plugin.description, dimmed: !plugin.isEnabled,
            expanded: !extraTags(plugin).isEmpty,
            badges: {
                OMTag("v\(plugin.version)")
                OMTag(plugin.scope, tint: OMColors.accent2)
                if !plugin.marketplace.isEmpty { OMTag(plugin.marketplace) }
            },
            trailing: {
                HStack(spacing: 8) {
                    OMSwitch(String(localized: "启用 \(plugin.name)"), isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { value in
                            Task { await center.runCLI(PluginStore.toggleArguments(plugin.pluginID, enable: value, scope: plugin.scope),
                                                       message: value ? String(localized: "正在启用…") : String(localized: "正在停用…"),
                                                       notice: value ? String(localized: "已启用 \(plugin.name),重启会话后生效") : String(localized: "已停用 \(plugin.name)")) }
                        }))
                        .disabled(actionsDisabled)
                    Button("更新") {
                        Task { await center.runCLI(PluginStore.updateArguments(plugin.pluginID), message: String(localized: "正在更新…"), notice: String(localized: "已更新 \(plugin.name),重启会话后生效")) }
                    }
                    .buttonStyle(.omSecondary).disabled(actionsDisabled)
                    Button("卸载") { pendingUninstall = plugin }.buttonStyle(.omDestructive).disabled(actionsDisabled)
                }
            },
            detail: {
                OMFlowLayout(spacing: 6) { ForEach(extraTags(plugin), id: \.self) { OMTag($0) } }
            }
        )
    }

    /// 插件携带的内容与作者标签(技能/命令/子 Agent/Hooks/MCP 数量等)。
    private func extraTags(_ plugin: InstalledPlugin) -> [String] {
        var tags: [String] = []
        if plugin.skillCount > 0 { tags.append(String(localized: "\(plugin.skillCount) 个 Skill")) }
        if plugin.commandCount > 0 { tags.append(String(localized: "\(plugin.commandCount) 个命令")) }
        if plugin.agentCount > 0 { tags.append(String(localized: "\(plugin.agentCount) 个子 Agent")) }
        if plugin.hasHooks { tags.append("Hooks") }
        tags += plugin.mcpServerNames.map { "MCP \($0)" }
        if !plugin.author.isEmpty { tags.append(String(localized: "作者 \(plugin.author)")) }
        return tags
    }

    // MARK: 市场

    private var marketplaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ExtensionSectionLabel(title: String(localized: "插件市场"), count: center.snapshot.marketplaces.count)
                Spacer()
                Button("全部更新") {
                    Task { await center.runCLI(PluginStore.marketplaceUpdateArguments(nil), message: String(localized: "正在更新市场…"), notice: String(localized: "市场已更新")) }
                }
                .buttonStyle(.omSecondary)
                .disabled(actionsDisabled || center.snapshot.marketplaces.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("GitHub 仓库 owner/repo、Git URL 或本地路径", text: $marketplaceSource).textFieldStyle(.omField).font(OMFonts.body)
                Button("添加市场") {
                    do {
                        try PluginStore.validateArgument(marketplaceSource)
                        let source = marketplaceSource.trimmingCharacters(in: .whitespaces)
                        Task { await center.runCLI(PluginStore.marketplaceAddArguments(source), message: String(localized: "正在添加市场…"), notice: String(localized: "已添加市场")) }
                        marketplaceSource = ""
                    } catch { center.lastError = error.localizedDescription }
                }
                .buttonStyle(.omPrimary)
                .disabled(marketplaceSource.isEmpty || actionsDisabled)
            }
            if !center.snapshot.marketplaces.isEmpty {
                ExtensionCardList {
                    ForEach(Array(center.snapshot.marketplaces.enumerated()), id: \.element.id) { index, market in
                        if index > 0 { ExtensionRowDivider() }
                        marketRow(market)
                    }
                }
            }
        }
    }

    private func marketRow(_ market: PluginMarketplace) -> some View {
        ExtensionRow(
            icon: "globe", title: market.name, subtitle: market.source, badges: { EmptyView() },
            trailing: {
                HStack(spacing: 8) {
                    if let updated = market.lastUpdated { Text(String(updated.prefix(10))).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
                    Button("更新") {
                        Task { await center.runCLI(PluginStore.marketplaceUpdateArguments(market.name), message: String(localized: "正在更新…"), notice: String(localized: "已更新 \(market.name)")) }
                    }
                    .buttonStyle(.omSecondary).disabled(actionsDisabled)
                    Button("移除") {
                        Task { await center.runCLI(PluginStore.marketplaceRemoveArguments(market.name), message: String(localized: "正在移除…"), notice: String(localized: "已移除 \(market.name)")) }
                    }
                    .buttonStyle(.omDestructive).disabled(actionsDisabled)
                }
            }
        )
    }
}
