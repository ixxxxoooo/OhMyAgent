// @author ygw
// 状态栏(22pt):左侧 Agent 连接状态与项目路径,右侧运行/未读计数,以及用量、工具与扩展、底部面板开关(无标题栏窗口,原工具栏按钮收纳于此)。后续里程碑加入分支、光标位置、LSP 等。

import AgentHost
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

struct StatusBarView: View {
    let workbench: WorkbenchModel
    let switchAgent: (AgentDescriptor) -> Void
    private let attention = AttentionCenter.shared

    var body: some View {
        HStack(spacing: 12) {
            if let model = workbench.activeSession {
                ConnectionBadge(model: model)
                AgentMenu(model: model, switchAgent: switchAgent)
                if case .failed = model.phase {
                    Text("请确认本机已安装 claude 并在终端登录过")
                        .foregroundStyle(OMColors.warning)
                }
            } else {
                Text("未打开项目")
            }
            if let project = workbench.selectedProject {
                Text((project.id as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            let running = attention.count(of: .running), input = attention.count(of: .needsInput), unread = attention.count(of: .unreadDone)
            if input > 0 { counter(color: .orange, text: String(localized: "\(input) 个等待处理")) }
            if running > 0 { counter(color: .blue, text: String(localized: "\(running) 个运行中")) }
            if unread > 0 { counter(color: .green, text: String(localized: "\(unread) 个未读")) }
            tools
        }
        .font(OMFonts.caption)
        .foregroundStyle(OMColors.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 右侧工具:用量、工具与扩展、底部面板开关(原窗口工具栏中的按钮)。
    private var tools: some View {
        HStack(spacing: 2) {
            if let usage = workbench.activeSession?.usage, usage.used != nil || usage.costAmount != nil {
                UsageButton(usage: usage)
            }
            statusButton(icon: "puzzlepiece.extension", label: String(localized: "工具与扩展"),
                         help: "MCP、Skills、子 Agent、Hooks、插件与记忆 (\(ShortcutStore.shared.binding(for: .extensions).display))") {
                AppActions.shared.openSettings(page: .tools)
            }
            statusButton(icon: "panel-bottom", label: String(localized: "底部面板"),
                         help: "切换底部面板 (\(ShortcutStore.shared.binding(for: .togglePanel).display))",
                         active: workbench.layout.bottomVisible) {
                workbench.toggleBottom()
            }
        }
    }

    private func statusButton(icon: String, label: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.om(icon, size: 12)
                .frame(width: 22, height: 18)
                .foregroundStyle(active ? OMColors.accent : OMColors.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func counter(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}
