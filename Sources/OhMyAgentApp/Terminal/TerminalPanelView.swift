// @author ixxxxoooo
// 终端面板(底部/左右栏共用):当前终端 + 终端切换入口。
// 只有一个终端时是简洁的单终端;≥2 个时右侧出现终端列表(可收起,收起后回到顶部标签条)。
// 参考 Cursor 的终端列表:每个条目对应一个常驻 shell,切换与隐藏面板都不会结束进程。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WorkbenchKit

/// 终端面板内容。
struct TerminalPanelView: View {
    @Bindable var workbench: WorkbenchModel
    /// 项目根目录(终端状态按它分组)
    let root: String
    private let store = TerminalPanelStore.shared
    private let agentStore = AgentTerminalStore.shared

    var body: some View {
        let state = store.state(for: root)
        let agents = agentStore.entries(for: root)
        let activeAgent = agentStore.activeID(for: root).flatMap { id in agents.first { $0.id == id } }
        let showsList = state.instances.count + agents.count >= 2 && !workbench.layout.terminalListCollapsed
        VStack(spacing: 0) {
            if !showsList {
                tabStrip(state, agents: agents, activeAgentID: activeAgent?.id)
                Divider()
            }
            HStack(spacing: 0) {
                Group {
                    if let activeAgent {
                        AgentTerminalContentView(session: activeAgent.session).id(activeAgent.id)
                    } else {
                        TerminalTabView(id: state.active.id, fallbackDirectory: root).id(state.active.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsList {
                    PanelResizer(width: $workbench.layout.terminalListWidth, side: .right,
                                 range: PanelMetrics.terminalListRange, defaultWidth: PanelMetrics.terminalListDefault)
                    TerminalListView(
                        state: state,
                        agents: agents.map { AgentListRowModel(id: $0.id, title: $0.session.command.isEmpty ? String(localized: "Agent 终端") : $0.session.command, isRunning: $0.session.isRunning) },
                        activeAgentID: activeAgent?.id,
                        onSelectAgent: { id in omWithAnimation { agentStore.activate(id, root: root) } },
                        onCloseAgent: { id in agentStore.close(id, root: root) },
                        titleOf: { store.title(of: $0) },
                        menu: { menu(for: $0, state: state) },
                        onSelect: { id in omWithAnimation { agentStore.activate(nil, root: root); store.activate(id, root: root) } },
                        onClose: { close($0) },
                        onRename: { id, name in store.rename(id, to: name, root: root) },
                        onMove: { id, target in store.move(id, before: target, root: root) },
                        onAdd: { AppActions.shared.newTerminal() },
                        onCollapse: { omWithAnimation { workbench.layout.terminalListCollapsed = true } }
                    )
                    .frame(width: workbench.layout.terminalListWidth)
                }
            }
        }
    }

    // MARK: 标签条

    private func tabStrip(_ state: TerminalPanelState, agents: [AgentTerminalEntry], activeAgentID: String?) -> some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.instances) { instance in
                        TerminalPanelTab(
                            title: store.title(of: instance),
                            isActive: instance.id == state.activeID && activeAgentID == nil,
                            canClose: true,
                            onSelect: { omWithAnimation { agentStore.activate(nil, root: root); store.activate(instance.id, root: root) } },
                            onClose: { close(instance.id) }
                        )
                        .omContextMenu { menu(for: instance, state: state) }
                    }
                    ForEach(agents) { agent in
                        TerminalPanelTab(
                            title: agent.session.command.isEmpty ? String(localized: "Agent 终端") : agent.session.command,
                            icon: "bot",
                            isActive: agent.id == activeAgentID,
                            canClose: true,
                            onSelect: { omWithAnimation { agentStore.activate(agent.id, root: root) } },
                            onClose: { agentStore.close(agent.id, root: root) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            if state.instances.count + agents.count >= 2 {
                Button { omWithAnimation { workbench.layout.terminalListCollapsed = false } } label: { Image.om("panel-right", size: 12) }
                    .buttonStyle(.omIcon)
                    .omTooltip("显示终端列表")
                    .accessibilityLabel("显示终端列表")
            }
            Button { AppActions.shared.newTerminal() } label: { Image.om("plus", size: 12) }
                .buttonStyle(.omIcon)
                .disabled(!state.canAdd)
                .omTooltip(String(localized: "新建终端 (\(ShortcutStore.shared.binding(for: .newTerminal).display))"))
                .accessibilityLabel("新建终端")
                .padding(.trailing, 6)
        }
        .frame(height: 28)
        .background(OMColors.surface)
    }

    @OMMenuBuilder
    private func menu(for instance: TerminalInstance, state: TerminalPanelState) -> [MenuEntry] {
        OMMenuItem("重命名…", icon: "pencil") { rename(instance) }
        OMMenuItem("恢复默认名称", icon: "rotate-ccw", isEnabled: instance.customTitle != nil) { store.rename(instance.id, to: "", root: root) }
        OMMenuDivider()
        OMMenuItem("关闭", icon: "x") { close(instance.id) }
        OMMenuItem("关闭其它", isEnabled: state.instances.count > 1) { store.closeOthers(keeping: instance.id, root: root) }
    }

    private func close(_ id: String) {
        if store.close(id, root: root) == .closedLast { workbench.hideTerminal() }
    }

    private func rename(_ instance: TerminalInstance) {
        guard let name = OMDialog.prompt(title: String(localized: "重命名终端"), initial: store.title(of: instance)) else { return }
        store.rename(instance.id, to: name, root: root)
    }
}

/// 终端标签:图标 + 标题 + 关闭按钮(悬停或激活时显示)。
private struct TerminalPanelTab: View {
    let title: String
    var icon = "square-terminal"
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image.om(icon, size: 12)
            Text(verbatim: title)
                .font(OMFonts.small)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: onClose) {
                Image.om("x", size: 10).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canClose && (hovering || isActive) ? 1 : 0)
            .omTooltip("关闭终端")
            .accessibilityLabel("关闭终端")
        }
        .foregroundStyle(isActive ? OMColors.primaryText : OMColors.secondaryText)
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 22)
        .background(isActive ? OMColors.selectedFill : (hovering ? OMColors.hoverFill : .clear), in: OMPillShape())
        .contentShape(OMPillShape())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}
