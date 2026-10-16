// @author ixxxxoooo
// 插件管理:已安装列表(启停/更新/卸载)、市场管理与安装。变更全部委托官方 `claude plugin` CLI。

import IconKit
import ClaudeConfigKit
import DesignSystem
import SwiftUI

/// 插件管理页。
struct PluginsManagerView: View {
    let center: ConfigCenter
    @State private var installName = ""
    @State private var marketplaceSource = ""
    @State private var installScope = "user"
    @State private var pendingInstall: String?
    @State private var pendingUninstall: InstalledPlugin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !center.canRunCLI {
                    Label("没有找到 claude 命令行工具,插件的安装/启停/卸载不可用(下方列表仍可只读查看)。", om: "exclamationmark.triangle")
                        .font(OMFonts.small).foregroundStyle(OMColors.warning)
                }
                installSection
                installedSection
                marketplaceSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("安装插件").font(OMFonts.title)
            HStack {
                TextField("plugin@marketplace", text: $installName).textFieldStyle(.roundedBorder).font(OMFonts.mono)
                Picker("", selection: $installScope) { Text("用户").tag("user"); Text("项目").tag("project"); Text("本地").tag("local") }
                    .labelsHidden().fixedSize()
                Button("安装…") {
                    do { try PluginStore.validateArgument(installName); pendingInstall = installName.trimmingCharacters(in: .whitespaces) }
                    catch { center.lastError = error.localizedDescription }
                }
                .disabled(installName.isEmpty || center.isBusy || !center.canRunCLI)
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已安装(\(center.snapshot.plugins.count))").font(OMFonts.title)
            if center.snapshot.plugins.isEmpty {
                Text("还没有安装插件。").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
            }
            ForEach(center.snapshot.plugins) { plugin in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(plugin.name).font(OMFonts.body.weight(.semibold))
                                Tag("v\(plugin.version)")
                                Tag(plugin.scope, color: OMColors.accent2)
                                if !plugin.marketplace.isEmpty { Tag(plugin.marketplace) }
                            }
                            if !plugin.description.isEmpty { Text(plugin.description).font(OMFonts.small).foregroundStyle(OMColors.secondaryText) }
                        }
                        Spacer()
                        OMSwitch(String(localized: "启用 \(plugin.name)"), isOn: Binding(
                            get: { plugin.isEnabled },
                            set: { value in
                                Task { await center.runCLI(PluginStore.toggleArguments(plugin.pluginID, enable: value, scope: plugin.scope),
                                                           message: value ? String(localized: "正在启用…") : String(localized: "正在停用…"), notice: value ? String(localized: "已启用 \(plugin.name),重启会话后生效") : String(localized: "已停用 \(plugin.name)")) }
                            }))
                            .disabled(center.isBusy || !center.canRunCLI)
                        Button("更新") { Task { await center.runCLI(PluginStore.updateArguments(plugin.pluginID), message: String(localized: "正在更新…"), notice: String(localized: "已更新 \(plugin.name),重启会话后生效")) } }
                            .disabled(center.isBusy || !center.canRunCLI)
                        Button("卸载", role: .destructive) { pendingUninstall = plugin }.disabled(center.isBusy || !center.canRunCLI)
                    }
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        if plugin.skillCount > 0 { Tag(String(localized: "\(plugin.skillCount) 个 Skill")) }
                        if plugin.commandCount > 0 { Tag(String(localized: "\(plugin.commandCount) 个命令")) }
                        if plugin.agentCount > 0 { Tag(String(localized: "\(plugin.agentCount) 个子 Agent")) }
                        if plugin.hasHooks { Tag("Hooks") }
                        ForEach(plugin.mcpServerNames, id: \.self) { Tag("MCP \($0)") }
                        if !plugin.author.isEmpty { Tag(String(localized: "作者 \(plugin.author)")) }
                    }
                }
                .padding(10)
                .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var marketplaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("插件市场(\(center.snapshot.marketplaces.count))").font(OMFonts.title)
                Spacer()
                Button("全部更新") { Task { await center.runCLI(PluginStore.marketplaceUpdateArguments(nil), message: String(localized: "正在更新市场…"), notice: String(localized: "市场已更新")) } }
                    .disabled(center.isBusy || !center.canRunCLI || center.snapshot.marketplaces.isEmpty)
            }
            HStack {
                TextField("GitHub 仓库 owner/repo、Git URL 或本地路径", text: $marketplaceSource).textFieldStyle(.roundedBorder)
                Button("添加市场") {
                    do {
                        try PluginStore.validateArgument(marketplaceSource)
                        let source = marketplaceSource.trimmingCharacters(in: .whitespaces)
                        Task { await center.runCLI(PluginStore.marketplaceAddArguments(source), message: String(localized: "正在添加市场…"), notice: String(localized: "已添加市场")) }
                        marketplaceSource = ""
                    } catch { center.lastError = error.localizedDescription }
                }
                .disabled(marketplaceSource.isEmpty || center.isBusy || !center.canRunCLI)
            }
            ForEach(center.snapshot.marketplaces) { market in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(market.name).font(OMFonts.body)
                        Text(market.source).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText)
                    }
                    Spacer()
                    if let updated = market.lastUpdated { Text(updated.prefix(10)).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText) }
                    Button("更新") { Task { await center.runCLI(PluginStore.marketplaceUpdateArguments(market.name), message: String(localized: "正在更新…"), notice: String(localized: "已更新 \(market.name)")) } }
                        .disabled(center.isBusy || !center.canRunCLI)
                    Button("移除", role: .destructive) { Task { await center.runCLI(PluginStore.marketplaceRemoveArguments(market.name), message: String(localized: "正在移除…"), notice: String(localized: "已移除 \(market.name)")) } }
                        .disabled(center.isBusy || !center.canRunCLI)
                }
                .controlSize(.small)
                .padding(.vertical, 2)
            }
        }
    }
}
