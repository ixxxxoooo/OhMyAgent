// @author ixxxxoooo
// 工作台根视图:左栏(项目 → 会话树)+ 中栏(会话)+ 右栏检查器(文件/搜索/Git/改动/计划)+ 底部面板。
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
        .overlay { PaletteOverlay(workbench: workbench) }
        .tint(appearance.accent.color)
        .frame(minWidth: 860, minHeight: 560)
        .background(WindowFocusReader(onWindow: { window in actions.mainWindow = window; WindowChrome.apply(to: window) }, onChange: { key in
            windowIsKey = key
            if let window = actions.mainWindow { WindowChrome.apply(to: window) }
            updateFocus()
        }))
        .onAppear {
            DiagnosticsStore.shared.markFirstFrame()
            actions.capture(openWindow: openWindow)
        }
        .onChange(of: workbench.dock.allTabs.compactMap(\.terminalID)) { _, ids in
            // 终端标签被关闭 → 结束其 shell 进程
            TerminalStore.shared.prune(keeping: Set(ids))
        }
        .onChange(of: workbench.activeSession?.uid) { _, _ in updateFocus() }
        .onChange(of: workbench.activeSession?.phase) { _, _ in consumeSessionRequest() }
        .onChange(of: actions.sessionRequest) { _, _ in consumeSessionRequest() }
        .task { await runDebugHooks() }
    }

    /// 工作台主体:左栏 + 中栏 + 右栏(自绘布局,无原生 NavigationSplitView);
    /// 顶部浮层(回退/前进/侧栏开关/右栏开关)盖在整个工作区之上,按钮位置恒定且可点击。
    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if workbench.layout.leftVisible {
                ProjectTreeView(workbench: workbench)
                    .id(appearance.fontRevision)
                    .frame(width: CGFloat(workbench.layout.leftWidth))
                    .clipped()
                    .background(SidebarBackground())
                PanelResizer(width: $workbench.layout.leftWidth, side: .left)
            }
            CenterColumn(workbench: workbench)
                .frame(minWidth: 320, maxWidth: .infinity)
            if workbench.layout.rightVisible {
                PanelResizer(width: $workbench.layout.rightWidth, side: .right)
                RightPaneView(workbench: workbench)
                    .frame(width: CGFloat(workbench.layout.rightWidth))
                    .clipped()
            }
        }
        .overlay(alignment: .top) { TitlebarOverlay(workbench: workbench) }
        .ignoresSafeArea(.container, edges: .top)
        // 无标题栏窗口:窗口标题仅保留给系统(Mission Control/辅助功能)。
        .navigationTitle(title)
        .onAppear { workbench.recordNavigation() }
        .onChange(of: navigationSignature) { _, _ in workbench.recordNavigation() }
    }

    /// 导航历史的触发信号:聚焦组的激活标签与标签总数(关闭标签时需要清理历史)。
    private var navigationSignature: NavigationSignature {
        NavigationSignature(active: workbench.dock.focusedGroup?.activeID, tabCount: workbench.dock.allTabs.count)
    }

    /// 导航历史触发信号。
    private struct NavigationSignature: Equatable {
        let active: UUID?
        let tabCount: Int
    }

    // MARK: 标题与布局

    private var title: String {
        workbench.activeSession?.sessionTitle ?? workbench.selectedProject?.name ?? "OhMyAgent"
    }

    // MARK: 行为

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
        var env = ProcessInfo.processInfo.environment
        // 调试:OMA_TOGGLE_LEFT=秒 延迟后切换左栏显隐(不依赖鼠标点击,用于脚本化验证左栏收起/展开)
        if let delay = env["OMA_TOGGLE_LEFT"], let seconds = Double(delay) {
            try? await Task.sleep(for: .seconds(seconds))
            workbench.toggleLeft()
        }
        // 演示模式:OMA_DEMO_SCENARIO=<场景名> 等价于 OMA_AUTOSEND="/demo-<场景名>"
        if let scenario = DemoLaunch.environment?.scenario, env["OMA_AUTOSEND"] == nil { env["OMA_AUTOSEND"] = "/demo-" + scenario }
        let wantsSession = env["OMA_AUTOSEND"] != nil || env["OMA_DRAFT"] != nil
        for _ in 0..<80 where workbench.activeSession == nil && (wantsSession || !workbench.projects.isEmpty) { try? await Task.sleep(for: .milliseconds(100)) }
        if let draft = env["OMA_DRAFT"], !draft.isEmpty { workbench.activeSession?.draft = draft }
        // 调试:OMA_ATTACH_IMAGE=图片路径1:图片路径2 给当前会话的输入框添加图片附件(配合 OMA_AUTOSEND 会一并发送)
        if let list = env["OMA_ATTACH_IMAGE"], !list.isEmpty, let model = workbench.activeSession {
            for path in list.split(separator: ":") {
                if let image = ImageIntake.attachment(from: URL(fileURLWithPath: String(path))) { model.addAttachment(image) }
                else { Log.app.warning("调试钩子:无法读取图片", ["path": String(path)]) }
            }
        }
        if let text = env["OMA_AUTOSEND"], !text.isEmpty, let model = workbench.activeSession {
            Log.app.debug("调试钩子:等待就绪后自动发送", ["project": model.workspace.lastPathComponent])
            for _ in 0..<100 where model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
            let images = model.attachments
            model.attachments = []
            model.send(text, images: images)
            if env["OMA_AUTOALLOW"] != nil {
                // 调试:自动批准本轮第一个权限请求(用于无人值守验证 Agent 编辑联动)
                for _ in 0..<100 where model.pendingPermissions.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                if let prompt = model.pendingPermissions.first { model.resolve(prompt, optionId: "allow") }
            }
        } else if env["OMA_AUTOSEND"] != nil {
            Log.app.warning("调试钩子:没有可用会话,未发送", ["active": "\(workbench.activeSession != nil)"])
        }
        if let toolID = env["OMA_OPEN_SUBAGENT"], !toolID.isEmpty, let project = workbench.selectedProjectID, let model = workbench.sessions[project] {
            // 调试:等待子 Agent 条目出现后以标签打开其只读会话
            for _ in 0..<60 where model.timeline.toolEntry(id: toolID) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            workbench.openSubagent(project: project, toolCallID: toolID, title: model.timeline.toolEntry(id: toolID)?.tool?.title ?? toolID)
        }
        if let pane = env["OMA_RIGHT_PANE"], let value = RightPane(rawValue: pane) {
            workbench.showRight(value)
            if let query = env["OMA_SEARCH_QUERY"] {
                SearchModel.shared.root = workbench.selectedProjectID
                WorkspaceIndexModel.shared.refresh(root: workbench.selectedProjectID)
                SearchModel.shared.query = query
            }
        }
        if let mode = env["OMA_PALETTE"] {
            // 调试:打开命令面板/快速打开,可预填查询
            PaletteModel.shared.present(mode == "commands" ? .commands : .files, workbench: workbench)
            try? await Task.sleep(for: .milliseconds(600))
            PaletteModel.shared.query = env["OMA_PALETTE_QUERY"] ?? ""
        }
        if let append = env["OMA_EDIT_APPEND"], !append.isEmpty, let file = env["OMA_OPEN_FILE"] {
            // 调试:等文件载入后追加文本,验证「未保存」标记;OMA_EDIT_SAVE=1 继续保存
            let doc = FileDocumentStore.shared.document(for: file)
            for _ in 0..<50 where doc.text == nil { try? await Task.sleep(for: .milliseconds(100)) }
            doc.text = (doc.text ?? "") + append
            if env["OMA_EDIT_SAVE"] == "1" {
                try? await Task.sleep(for: .milliseconds(800))
                actions.saveActiveFile()
            }
        }
        if let source = env["OMA_OPEN_MERMAID"], !source.isEmpty {
            // 调试:直接以预览标签打开一段 Mermaid 源码(\n 表示换行)
            let id = MermaidPreviewStore.shared.register(source.replacingOccurrences(of: "\\n", with: "\n"))
            workbench.openPreview(id: id, title: String(localized: "Mermaid 图"))
        }
        if let diffPath = env["OMA_OPEN_DIFF"], !diffPath.isEmpty { workbench.openDiff(diffPath) }  // 调试:打开 Diff 标签
        if let history = env["OMA_OPEN_HISTORY"], let project = workbench.selectedProjectID {
            workbench.openHistory(project: project, path: history.hasPrefix("/") ? history : nil)  // 调试:打开历史(可带文件路径)
        }
        if let blame = env["OMA_OPEN_BLAME"], !blame.isEmpty { workbench.openBlame(blame) }  // 调试:打开 blame
        if env["OMA_OPEN_TERMINAL"] != nil {
            // 调试:打开终端标签;OMA_TERM_INPUT 在 shell 就绪后输入(\n 会被替换为回车)
            actions.openTerminal()
            if let input = env["OMA_TERM_INPUT"], !input.isEmpty {
                try? await Task.sleep(for: .milliseconds(2000))
                TerminalStore.shared.controllers.values.first?.send(input.replacingOccurrences(of: "\\n", with: "\r"))
            }
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
        if let pane = env["OMA_BOTTOM_PANE"].flatMap(BottomPane.init(rawValue:)) { workbench.layout.bottomPane = pane }
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
