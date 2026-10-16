// @author ixxxxoooo
// 对话内的 MCP 面板:列出本机配置的 MCP 服务器及连接状态,可重连/启用/停用(经适配器的 `/mcp` 命令),
// 并跳转设置页的完整管理界面。状态来自 `claude mcp list`,与设置页共用同一份数据。

import ChatKit
import ClaudeConfigKit
import DesignSystem
import IconKit
import SwiftUI

/// 输入区工具栏上的 MCP 按钮(弹出面板)。
struct MCPPanelButton: View {
    let model: SessionModel
    @State private var shown = false
    private let router = ChatPanelRouter.shared

    var body: some View {
        let center = ProjectConfigHub.shared.center(for: model.workspace)
        let servers = center.snapshot.mcp.filter { $0.overriddenBy == nil }
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Image.om("plug", size: 12)
                if !servers.isEmpty { Text("\(servers.count)").font(OMFonts.small) }
                if hasProblem(servers, center: center) {
                    Circle().fill(OMColors.warning).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(OMColors.secondaryText)
        }
        .buttonStyle(.plain)
        .help("MCP 服务器")
        .accessibilityLabel("MCP 服务器")
        .popover(isPresented: $shown, arrowEdge: .top) {
            MCPPanelView(model: model, center: center, dismiss: { shown = false })
        }
        .onChange(of: router.mcpNonce) { _, _ in
            if router.mcpTarget === model { shown = true }
        }
    }

    /// 是否有连接异常(失败/需要认证)的服务器。
    private func hasProblem(_ servers: [MCPServerEntry], center: ConfigCenter) -> Bool {
        servers.contains { entry in
            guard !entry.isDisabled, let health = center.mcpHealth[entry.config.name] else { return false }
            return health.state == .failed || health.state == .needsAuth
        }
    }
}

/// MCP 面板内容。
struct MCPPanelView: View {
    let model: SessionModel
    let center: ConfigCenter
    let dismiss: () -> Void

    private var servers: [MCPServerEntry] { center.snapshot.mcp.filter { $0.overriddenBy == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if servers.isEmpty {
                VStack(spacing: 8) {
                    Image.om("plug", size: 22).foregroundStyle(OMColors.tertiaryText)
                    Text("还没有配置 MCP 服务器")
                        .font(OMFonts.body)
                    Text("MCP 让 Claude 连接外部工具与数据(GitHub、数据库、浏览器……)。")
                        .font(OMFonts.small)
                        .foregroundStyle(OMColors.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("添加服务器…") {
                        dismiss()
                        AppActions.shared.openSettings(page: .mcp)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(servers) { entry in
                            row(entry)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .task {
            if center.mcpHealth.isEmpty, center.canRunCLI { await center.checkMCPHealth() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image.om("plug", size: 13)
            Text("MCP 服务器").font(OMFonts.body.weight(.semibold))
            Spacer()
            if center.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await center.checkMCPHealth() }
                } label: {
                    Image.om("refresh-cw", size: 12)
                }
                .buttonStyle(.plain)
                .disabled(!center.canRunCLI)
                .help("重新检测连接状态")
                .accessibilityLabel("重新检测连接状态")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func row(_ entry: MCPServerEntry) -> some View {
        let health = center.mcpHealth[entry.config.name]
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(entry, health)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.config.name).font(OMFonts.body.weight(.medium)).lineLimit(1)
                    Text(entry.scope.displayName)
                        .font(OMFonts.caption)
                        .foregroundStyle(OMColors.secondaryText)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Text(statusText(entry, health))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.secondaryText)
                    .lineLimit(2)
                Text(summary(entry.config))
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            actions(entry)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actions(_ entry: MCPServerEntry) -> some View {
        let name = entry.config.name
        HStack(spacing: 4) {
            if !entry.isDisabled {
                Button {
                    model.sendToAgent("/mcp reconnect \(name)")
                    dismiss()
                } label: {
                    Image.om("rotate-cw", size: 12).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .help("在当前会话中重连")
                .accessibilityLabel("重连 \(name)")
            }
            Button {
                model.sendToAgent("/mcp \(entry.isDisabled ? "enable" : "disable") \(name)")
                dismiss()
            } label: {
                Image.om("power", size: 12).frame(width: 22, height: 22)
                    .foregroundStyle(entry.isDisabled ? OMColors.secondaryText : OMColors.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            .help(entry.isDisabled ? String(localized: "在当前会话中启用") : String(localized: "在当前会话中停用"))
            .accessibilityLabel(entry.isDisabled ? String(localized: "启用 \(name)") : String(localized: "停用 \(name)"))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.sendToAgent("/mcp")
                dismiss()
            } label: {
                Label("会话内状态", om: "activity")
            }
            .disabled(model.isRunning)
            .help("让 Agent 汇报本会话中各服务器的连接情况与工具数")
            Spacer()
            Button {
                dismiss()
                AppActions.shared.openSettings(page: .mcp)
            } label: {
                Label("管理…", om: "settings")
            }
        }
        .buttonStyle(.plain)
        .font(OMFonts.small)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: - 展示辅助

    private func color(_ entry: MCPServerEntry, _ health: MCPHealthStatus?) -> Color {
        if entry.isDisabled { return OMColors.tertiaryText }
        switch health?.state {
        case .connected: return .green
        case .needsAuth: return OMColors.warning
        case .failed: return .red
        default: return OMColors.tertiaryText
        }
    }

    private func statusText(_ entry: MCPServerEntry, _ health: MCPHealthStatus?) -> String {
        if entry.isDisabled { return String(localized: "已停用") }
        if entry.needsApproval { return String(localized: "项目级服务器,等待批准") }
        switch health?.state {
        case .connected: return String(localized: "已连接")
        case .needsAuth: return String(localized: "需要认证:在终端运行 claude,执行 /mcp 完成授权")
        case .failed: return health?.detail.isEmpty == false ? (health?.detail ?? "") : String(localized: "连接失败")
        default: return center.isBusy ? String(localized: "检测中…") : String(localized: "状态未知")
        }
    }

    private func summary(_ config: MCPServerConfig) -> String {
        switch config.transport {
        case .stdio: return ([config.command] + config.args).joined(separator: " ")
        default: return config.url
        }
    }
}
