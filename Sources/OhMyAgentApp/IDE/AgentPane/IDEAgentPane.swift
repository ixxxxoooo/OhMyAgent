// @author ixxxxoooo
// IDE 窗口右侧的 Agent 面板:嵌入与 Agents Window 同一套对话界面(`ChatView`),
// 顶部栏对齐 Cursor(会话标签条 + 新对话/历史/最大化/收起)。
// 非融合模式:会话使用本窗口专属的槽位(不与 Agents Window 的会话标签冲突);
// 融合模式:直接取工作台里该项目的当前会话,与 Agents Window 共用同一个会话与标签。文件引用在本窗口的编辑器里打开。

import ACPKit
import ChatKit
import DesignSystem
import IconKit
import IDEKit
import OMLog
import SwiftUI
import WorkbenchKit

struct IDEAgentPane: View {
    let workspace: IDEWorkspace
    private let appearance = AppearanceModel.shared
    private let fusion = FusionMode.shared
    /// 历史会话下拉是否展开
    @State private var historyShown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(OMColors.hairline).frame(height: 1)
            content
        }
        .frame(maxHeight: .infinity)
        .background(OMColors.surface)
    }

    /// 标签条里的一项。
    struct PaneTab: Identifiable {
        let id: UUID
        let title: String
        let isActive: Bool
        let isRunning: Bool
        /// 是否可关闭(融合模式下对应工作台的会话标签才可关)
        let closable: Bool
    }

    /// 顶部栏:标签样式与编辑器标签栏(`IDETabBar`)一致;空白处双击新建对话(同 VS Code 标签栏),
    /// 右侧依次为「新对话 / 历史 / 最大化 / 收起面板」。
    private var header: some View {
        HStack(spacing: 0) {
            tabStrip
            HStack(spacing: 2) {
                iconButton("plus", String(localized: "新对话")) { workspace.newAgentConversation() }
                iconButton("clock", String(localized: "历史对话")) { historyShown.toggle() }
                    .omPicker(isPresented: $historyShown, entries: historyEntries, selectedID: workspace.agentSession?.sessionId,
                              placeholder: String(localized: "搜索历史对话"), placement: .belowTrailing, width: 300, showsSearch: true) { entry in
                        workspace.openAgentHistory(sessionID: entry.id, title: entry.title)
                    }
                iconButton(workspace.model.agentPaneMaximized ? "minimize-2" : "maximize-2",
                           workspace.model.agentPaneMaximized ? String(localized: "还原 Agent 面板") : String(localized: "最大化 Agent 面板")) {
                    workspace.model.toggleAgentMaximized()
                }
                iconButton("panel-right-close", String(localized: "关闭")) { workspace.model.toggleAgentPane() }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: IDETabMetrics.height)
        .background(OMColors.sidebar)
    }

    /// 会话标签条:融合模式下就是工作台里该项目打开的全部会话标签(与 Agent 窗口一致);否则只有本面板的一个会话。
    private var tabStrip: some View {
        let tabs = paneTabs
        return GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in tabView(tab) }
                    // 标签之后的空白区:双击新建对话(同 VS Code 标签栏)
                    Color.clear
                        .frame(minWidth: 16, maxWidth: .infinity, minHeight: IDETabMetrics.height)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { workspace.newAgentConversation() }
                }
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// 单个会话标签:与编辑器标签同款(激活底色、顶部强调线、右侧分隔线、悬停显示关闭、中键关闭)。
    private func tabView(_ tab: PaneTab) -> some View {
        PaneTabItem(tab: tab, onActivate: { workspace.activateAgentTab(tab.id) }, onClose: { workspace.closeAgentTab(tab.id) })
    }

    /// 标签条数据。
    private var paneTabs: [PaneTab] {
        let workbench = AppEnvironment.shared.workbench
        if fusion.isEnabled, let projectID = workspace.agentProjectID {
            let active = workbench.activeChatTabID(in: projectID)
            let tabs = workbench.chatTabs(in: projectID)
            if !tabs.isEmpty {
                return tabs.map { tab in
                    PaneTab(id: tab.id, title: workbench.displayTitle(tab), isActive: tab.id == active,
                            isRunning: workbench.session(forTab: tab)?.isRunning ?? false, closable: true)
                }
            }
        }
        let session = workspace.agentSession
        let title = session?.sessionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "新对话")
        return [PaneTab(id: workspace.model.id, title: title, isActive: true, isRunning: session?.isRunning ?? false, closable: true)]
    }

    /// 历史对话下拉的条目(新的在前;已归档/已删除的不列出)。
    private var historyEntries: [PickEntry] {
        guard let projectID = workspace.agentProjectID,
              let project = AppEnvironment.shared.workbench.projects.first(where: { $0.id == projectID }) else { return [] }
        let hidden = Set(project.archivedSessions + project.deletedSessions)
        return project.sessions
            .filter { !hidden.contains($0.sessionId) }
            .sorted { ($0.createdAt ?? $0.updatedAt ?? "") > ($1.createdAt ?? $1.updatedAt ?? "") }
            .map { PickEntry(id: $0.sessionId, title: $0.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未命名对话")) }
    }

    @ViewBuilder
    private var content: some View {
        if workspace.root == nil {
            OMEmptyState { Label("Agent 面板", om: "sparkles") } description: { Text("打开文件夹后即可在这里与 Agent 对话") }
        } else if let session = workspace.agentSession {
            ChatView(model: session)
                .id("\(appearance.renderKey)-\(session.uid)")
                .environment(session)
        } else {
            OMSpinner(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: workspace.root) { workspace.prepareAgentSession() }
        }
    }

    private func iconButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 14) }
            .buttonStyle(.omIcon)
            .omTooltip(title)
            .accessibilityLabel(title)
    }
}

/// Agent 面板里的单个会话标签。
private struct PaneTabItem: View {
    let tab: IDEAgentPane.PaneTab
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isRunning { OMSessionDot(.running, size: 6) }
            Text(verbatim: tab.title)
                .font(OMFonts.small)
                .foregroundStyle(tab.isActive ? OMColors.primaryText : OMColors.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: IDETabMetrics.maxLabelWidth, alignment: .leading)
            if tab.closable {
                Button(action: onClose) { Image.om("x", size: 12) }
                    .buttonStyle(.omIcon)
                    .opacity(tab.isActive || hovering ? 1 : 0)
                    .frame(width: 16, height: 16)
                    .omTooltip(String(localized: "关闭对话"))
                    .accessibilityLabel(String(localized: "关闭对话"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: IDETabMetrics.height)
        .background(tab.isActive ? OMColors.contentBackground : (hovering ? OMColors.hoverFill : Color.clear))
        .overlay(alignment: .top) {
            if tab.isActive { Rectangle().fill(OMColors.accent).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(OMColors.hairline).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onActivate)
        .background(MiddleClickCatcher { if tab.closable { onClose() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isActive ? [.isButton, .isSelected] : .isButton)
    }
}

extension IDEWorkspace {
    /// 本窗口 Agent 面板使用的会话(未创建为 nil)。
    /// 融合模式:就是工作台里该项目的「当前会话」,与 Agent 窗口共用同一个 `SessionModel`(提问、输出、草稿实时同步);
    /// 非融合模式:使用本窗口专属槽位的独立会话。
    var agentSession: SessionModel? {
        guard let projectID = agentProjectID else { return nil }
        let workbench = AppEnvironment.shared.workbench
        if FusionMode.shared.isEnabled { return workbench.sessions[projectID] }
        return workbench.conversations[ConversationKey(projectID: projectID, slot: agentSlot)]
    }

    /// 确保工作区在工作台里登记为项目,并让面板拿到会话。
    /// 非融合:不改变 Agents Window 当前选中的项目,创建本窗口专属会话;
    /// 融合:项目在工作台里至少有一个会话标签(否则选中它让标签存在,再把原选中项目还原),面板直接取项目当前会话。
    func prepareAgentSession() {
        guard let root, FileManager.default.fileExists(atPath: root) else { return }
        let workbench = AppEnvironment.shared.workbench
        let projectID: String
        if let existing = workbench.projects.first(where: { IDEMetrics.normalizedRoot($0.id) == root }) {
            projectID = existing.id
        } else {
            let previous = workbench.selectedProjectID
            guard let created = workbench.openProject(URL(fileURLWithPath: root)) else { return }
            projectID = created
            // 登记项目会顺带选中它;Agents Window 的当前项目保持不变
            if let previous, previous != created { workbench.select(project: previous) }
        }
        agentProjectID = projectID
        let started = ContinuousClock.now
        if FusionMode.shared.isEnabled {
            if workbench.chatTabs(in: projectID).isEmpty {
                let previous = workbench.selectedProjectID
                workbench.select(project: projectID)
                if let previous, previous != projectID { workbench.select(project: previous) }
            }
            workbench.ensureSession(for: projectID)
        } else {
            workbench.ensureSession(project: projectID, slot: agentSlot)
        }
        Log.ui.info("IDE Agent 面板会话就绪", ["project": (projectID as NSString).lastPathComponent, "slot": agentSlot ?? "-", "fusion": "\(FusionMode.shared.isEnabled)", "ms": "\(Int((ContinuousClock.now - started).seconds * 1000))"])
    }

    /// 开始一个新对话。融合模式下在工作台里新开会话标签(Agent 窗口同步出现);否则换本窗口的槽位。
    func newAgentConversation() {
        if FusionMode.shared.isEnabled {
            if agentProjectID == nil { prepareAgentSession() }
            guard let projectID = agentProjectID else { return }
            AppEnvironment.shared.workbench.newConversation(in: projectID)
            return
        }
        agentSlot = "ide-" + UUID().uuidString.prefix(8).lowercased()
        prepareAgentSession()
    }

    /// 切到标签条里的某个会话标签(仅融合模式有多个标签)。
    /// - Parameter tabID: 工作台会话标签 ID
    func activateAgentTab(_ tabID: UUID) {
        guard FusionMode.shared.isEnabled else { return }
        AppEnvironment.shared.workbench.activateTab(tabID)
    }

    /// 关闭标签条里的某个会话标签。
    /// - Parameter tabID: 工作台会话标签 ID
    func closeAgentTab(_ tabID: UUID) {
        guard FusionMode.shared.isEnabled else {
            // 非融合:本面板只有一个会话。空白会话关闭 = 收起面板;已有内容的会话关闭 = 换成新的空白对话(旧的留在历史里)
            if agentSession?.isPristine == true { model.agentPaneVisible = false } else { newAgentConversation() }
            return
        }
        let workbench = AppEnvironment.shared.workbench
        // 会话标签还没建立时(占位标签):关闭 = 收起面板
        guard workbench.anyTab(tabID) != nil else { model.agentPaneVisible = false; return }
        workbench.closeTab(tabID)
    }

    /// 打开历史对话。融合模式:在工作台新开(或切到已打开的)会话标签,Agent 窗口同步;
    /// 非融合:把它载入本面板的会话。
    /// - Parameters:
    ///   - sessionID: 协议会话 ID
    ///   - title: 标题
    func openAgentHistory(sessionID: String, title: String) {
        guard let projectID = agentProjectID else { return }
        if FusionMode.shared.isEnabled {
            AppEnvironment.shared.workbench.openHistory(project: projectID, sessionId: sessionID, title: title)
        } else {
            agentSession?.openSession(SessionSummary(sessionId: sessionID, cwd: projectID, title: title))
        }
    }

    /// 把文件(或选区)作为 `@引用` 追加到 Agent 面板的输入框,并显示面板。
    /// - Parameter token: 引用标记(如 `@Sources/A.swift:12-20`)
    func addReferenceToChat(_ token: String) {
        model.agentPaneVisible = true
        if agentSession == nil { prepareAgentSession() }
        guard let session = agentSession else { return }
        session.draft = EditorReference.appending(token, to: session.draft)
    }

    /// 把当前编辑器文件作为引用加入对话。
    func addActiveFileToChat() {
        guard let path = model.activeFilePath, let root else { return }
        let display = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        addReferenceToChat("@" + display)
    }
}
