// @author ygw
// 工作台根视图:左栏(项目 → 会话树)+ 中栏(会话)+ 右栏检查器(变更/计划)+ 底部面板 + 状态栏。
// 左右栏均可收起,尺寸与显隐持久化到 WorkbenchModel.layout。

import IconKit
import ACPKit
import AgentHost
import ChatKit
import DesignSystem
import OMLog
import SwiftUI
import WorkbenchKit

/// 工作台根视图。
struct WorkbenchView: View {
    @Bindable var workbench: WorkbenchModel
    @Environment(\.openWindow) private var openWindow
    private let appearance = AppearanceModel.shared
    private let actions = AppActions.shared
    @State private var windowIsKey = false

    var body: some View {
        Group {
            if workbench.mode == .settings {
                SettingsView(workbench: workbench)
            } else {
                workspaceBody
            }
        }
        .tint(appearance.accent.color)
        .frame(minWidth: 860, minHeight: 560)
        .background(WindowFocusReader(onWindow: { actions.mainWindow = $0 }, onChange: { key in
            windowIsKey = key
            updateFocus()
        }))
        .onAppear {
            DiagnosticsStore.shared.markFirstFrame()
            actions.capture(openWindow: openWindow)
        }
        .onChange(of: workbench.activeSession?.uid) { _, _ in updateFocus() }
        .onChange(of: workbench.activeSession?.phase) { _, _ in consumeSessionRequest() }
        .onChange(of: actions.sessionRequest) { _, _ in consumeSessionRequest() }
        .task { await runDebugHooks() }
    }

    /// 工作台主体:左栏 + 中栏 + 右栏 + 状态栏。
    private var workspaceBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: columnVisibility) {
                    ProjectTreeView(workbench: workbench)
                        .id(appearance.fontRevision)
                        .navigationSplitViewColumnWidth(min: 220, ideal: CGFloat(workbench.layout.leftWidth), max: 420)
                } detail: {
                    CenterColumn(workbench: workbench)
                        .navigationTitle(title)
                        .navigationSubtitle(subtitle)
                        .toolbar { WorkbenchToolbar(workbench: workbench, switchAgent: switchAgent) }
                }
                .inspector(isPresented: $workbench.layout.rightVisible) {
                    RightPaneView(workbench: workbench)
                        .inspectorColumnWidth(min: 280, ideal: CGFloat(workbench.layout.rightWidth), max: 640)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if width > 0 { workbench.layout.rightWidth = Double(width) }
                        }
                }
                if !workbench.layout.rightVisible { RightRail(workbench: workbench) }
            }
            StatusBarView(workbench: workbench)
        }
    }

    // MARK: 标题与布局

    private var title: String {
        workbench.activeSession?.sessionTitle ?? workbench.selectedProject?.name ?? "OhMyAgent"
    }

    private var subtitle: String {
        workbench.selectedProject.map { ($0.id as NSString).abbreviatingWithTildeInPath } ?? ""
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { workbench.layout.leftVisible ? .all : .detailOnly },
            set: { workbench.layout.leftVisible = $0 != .detailOnly }
        )
    }

    // MARK: 行为

    /// 当前项目内切换 Agent:结束旧会话进程,用新描述符开始新会话。
    private func switchAgent(_ descriptor: AgentDescriptor) {
        guard let id = workbench.selectedProjectID, let current = workbench.activeSession, descriptor.id != current.descriptor.id else { return }
        Log.session.info("切换 Agent", ["project": id, "from": current.descriptor.id, "to": descriptor.id])
        workbench.replaceSession(for: id, with: AppEnvironment.makeSession(workspace: current.workspace, descriptor: descriptor))
    }

    /// 窗口为 key 时,当前会话视为「正在被查看」:其未读完成状态立即清除。
    private func updateFocus() {
        AttentionCenter.shared.setFocus(windowIsKey ? workbench.activeSession?.uid : nil)
    }

    /// 响应托盘/通知发起的「打开会话」请求:仅处理属于当前项目、且连接就绪时的请求。
    private func consumeSessionRequest() {
        guard let request = actions.sessionRequest, let id = workbench.selectedProjectID,
              id == URL(fileURLWithPath: request.workspacePath).standardizedFileURL.path,
              let model = workbench.activeSession, model.phase == .ready else { return }
        actions.sessionRequest = nil
        AttentionCenter.shared.markRead(model.uid)
        if let sessionId = request.sessionId, sessionId != model.sessionId {
            workbench.openHistory(project: id, sessionId: sessionId, title: request.title)
        }
    }

    /// 调试钩子(脚本化界面验证用,不影响正常使用)。
    private func runDebugHooks() async {
        let env = ProcessInfo.processInfo.environment
        let wantsSession = env["OMA_AUTOSEND"] != nil || env["OMA_DRAFT"] != nil
        for _ in 0..<80 where workbench.activeSession == nil && (wantsSession || !workbench.projects.isEmpty) { try? await Task.sleep(for: .milliseconds(100)) }
        if let draft = env["OMA_DRAFT"], !draft.isEmpty { workbench.activeSession?.draft = draft }
        if let text = env["OMA_AUTOSEND"], !text.isEmpty, let model = workbench.activeSession {
            Log.app.debug("调试钩子:等待就绪后自动发送", ["project": model.workspace.lastPathComponent])
            for _ in 0..<100 where model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
            model.send(text)
        } else if env["OMA_AUTOSEND"] != nil {
            Log.app.warning("调试钩子:没有可用会话,未发送", ["active": "\(workbench.activeSession != nil)"])
        }
        if let toolID = env["OMA_OPEN_SUBAGENT"], !toolID.isEmpty, let project = workbench.selectedProjectID, let model = workbench.sessions[project] {
            // 调试:等待子 Agent 条目出现后以标签打开其只读会话
            for _ in 0..<60 where model.timeline.toolEntry(id: toolID) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            workbench.openSubagent(project: project, toolCallID: toolID, title: model.timeline.toolEntry(id: toolID)?.tool?.title ?? toolID)
        }
        if let source = env["OMA_OPEN_MERMAID"], !source.isEmpty {
            // 调试:直接以预览标签打开一段 Mermaid 源码(\n 表示换行)
            let id = MermaidPreviewStore.shared.register(source.replacingOccurrences(of: "\\n", with: "\n"))
            workbench.openPreview(id: id, title: "Mermaid 图")
        }
        if let file = env["OMA_OPEN_FILE"], !file.isEmpty {
            // 调试:打开文件标签;OMA_SPLIT=right|bottom 时把它拖到会话组的对应边缘分屏
            let id = workbench.openFile(file, line: env["OMA_OPEN_LINE"].flatMap(Int.init), preview: false)
            if let side = env["OMA_SPLIT"], let zone = DockDropZone(rawValue: side),
               let chat = workbench.dock.allTabs.first(where: { if case .chat = $0.kind { return true } else { return false } }),
               let group = workbench.dock.location(of: chat.id)?.group {
                workbench.dock.drop(id, onGroup: group, zone: zone)
            }
        }
        if env["OMA_SHOW_RIGHT"] != nil { workbench.layout.rightVisible = true }
        if env["OMA_SHOW_BOTTOM"] != nil { workbench.layout.bottomVisible = true }
        if env["OMA_OPEN_SETTINGS"] != nil {
            workbench.openSettings()
        }
    }
}

/// 中栏:停靠区(标签组与分屏)+ 底部面板。
struct CenterColumn: View {
    @Bindable var workbench: WorkbenchModel

    var body: some View {
        VStack(spacing: 0) {
            DockView(workbench: workbench)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if workbench.layout.bottomVisible {
                BottomPanelView(workbench: workbench)
            }
        }
        .onChange(of: pendingViewerRequest) { _, request in
            // 统一打开入口:工具行/Bridge/改动汇总发出的「查看文件」请求都变成文件标签
            guard let request, let model = workbench.sessions.values.first(where: { $0.viewerRequest == request }) else { return }
            model.viewerRequest = nil
            workbench.openFile(request.path, line: request.line)
        }
    }

    /// 任一会话中待处理的文件查看请求。
    private var pendingViewerRequest: FileViewRequest? {
        workbench.sessions.values.lazy.compactMap(\.viewerRequest).first
    }
}

/// 工具栏:Agent 切换、用量、工具与扩展、新对话、右栏与底部面板开关。
struct WorkbenchToolbar: ToolbarContent {
    let workbench: WorkbenchModel
    let switchAgent: (AgentDescriptor) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let model = workbench.activeSession { AgentMenu(model: model, switchAgent: switchAgent) }
        }
        ToolbarItem(placement: .primaryAction) {
            if let usage = workbench.activeSession?.usage, usage.used != nil || usage.costAmount != nil {
                UsageButton(usage: usage)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                AppActions.shared.openSettings(page: .tools)
            } label: {
                Label("工具与扩展", om: "puzzlepiece.extension")
            }
            .help("MCP、Skills、子 Agent、Hooks、插件与记忆 (\(ShortcutStore.shared.binding(for: .extensions).display))")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            } label: {
                Label("新对话", om: "square.and.pencil")
            }
            .help("新对话 (\(ShortcutStore.shared.binding(for: .newConversation).display))")
            .disabled(workbench.activeSession?.phase != .ready)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { workbench.toggleBottom() } label: {
                Label("底部面板", om: workbench.layout.bottomVisible ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset.filled")
                    .symbolVariant(workbench.layout.bottomVisible ? .fill : .none)
            }
            .help("切换底部面板 (\(ShortcutStore.shared.binding(for: .togglePanel).display))")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { workbench.toggleRight() } label: {
                Label("右栏", om: "sidebar.right")
            }
            .help("切换右栏 (\(ShortcutStore.shared.binding(for: .toggleInspector).display))")
        }
    }
}
