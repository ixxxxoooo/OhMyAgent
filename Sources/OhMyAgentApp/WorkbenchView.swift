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
    @State private var compact = CompactLayout()

    var body: some View {
        Group {
            if workbench.mode == .settings {
                SettingsView(workbench: workbench)
            } else {
                workspaceBody
            }
        }
        .overlay { HubOverlay(workbench: workbench) }
        .omScrollbarPolicy()
        .overlay { MermaidFloatingOverlay() }
        .overlay { ImagePreviewOverlay() }
        .tint(appearance.tint)
        .frame(minWidth: 480, minHeight: 480)
        // 最小模式:窗口足够窄时自动收起左/右栏,拉宽后恢复(对照 Cursor)
        // 只观察宽度「档位」:拖动窗口时宽度每帧都变,但档位仅在跨越阈值时才变,action 不会逐帧触发;
        // action 内对布局副本更新,无变化则不写回(inout 直接传 `&workbench.layout` 会无条件通知所有观察者)
        .onGeometryChange(for: CompactLayout.Bucket.self) { CompactLayout.bucket(for: Double($0.size.width)) } action: { bucket in
            guard let width = bucket.representativeWidth else { return }
            var copy = workbench.layout
            compact.update(width: width, layout: &copy)
            guard copy != workbench.layout else { return }
            // 拖动窗口时的自动收起/恢复不做动画(界面本就在连续变化)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { workbench.layout = copy }
        }
        .background(WindowFocusReader(onWindow: { window in actions.mainWindow = window; WindowChrome.apply(to: window) }, onChange: { key in
            windowIsKey = key
            if let window = actions.mainWindow { WindowChrome.apply(to: window) }
            updateFocus()
        }))
        .onAppear {
            DiagnosticsStore.shared.markFirstFrame()
            actions.capture(openWindow: openWindow)
            MouseNavigationMonitor.install(workbench: workbench)
        }
        .onChange(of: workbench.allDockTabs.compactMap(\.terminalID)) { _, ids in
            // 终端标签被关闭 → 结束其 shell 进程
            TerminalStore.shared.prune(keeping: Set(ids))
        }
        .onChange(of: workbench.selectedProject?.id, initial: true) { _, id in WorkspaceWatchCenter.shared.watch(root: id, extras: workbench.selectedProject?.extraFolders ?? []) }
        .onChange(of: workbench.selectedProject?.extraFolders ?? []) { _, extras in WorkspaceWatchCenter.shared.watch(root: workbench.selectedProject?.id, extras: extras) }
        .onChange(of: workbench.activeSession?.uid) { _, _ in updateFocus() }
        .onChange(of: workbench.activeSession?.phase) { _, _ in consumeSessionRequest() }
        .onChange(of: actions.sessionRequest) { _, _ in consumeSessionRequest() }
        .task { await runDebugHooks() }
    }

    /// 工作台主体:左侧各列 + 中栏 + 右侧各列(自绘布局,无原生 NavigationSplitView);
    /// 项目栏、工具栏、终端侧栏落在哪一侧由 `layout.placement` 决定(设置 → 外观 → 布局)。
    /// 顶部浮层(回退/前进/面板开关)盖在整个工作区之上,按钮位置恒定且可点击。
    private var workspaceBody: some View {
        HStack(spacing: 0) {
            ForEach(workbench.layout.visibleColumns(on: .left)) { panelColumn($0, side: .left) }
            CenterColumn(workbench: workbench)
                .frame(minWidth: 280, maxWidth: .infinity)
            // 右侧由内向外排列
            ForEach(workbench.layout.visibleColumns(on: .right).reversed()) { panelColumn($0, side: .right) }
        }
        // 面板显隐的滑入/滑出动画只挂在面板自己的 transition 上(见 `panelTransition`),这里不给整个 HStack 加动画:
        // 否则中栏的宽度会逐帧变化,整条会话时间线与所有常驻会话标签每帧重新排版,开关侧栏就会掉帧。
        // 现在中栏一次性排到最终宽度,面板在其上方做位移 + 淡入淡出(拖动宽度同样不受影响)。
        .onChange(of: panelVisibilitySignature) { _, _ in PanelToggleProbe.begin(stamp: workbench.panelToggleStamp, window: actions.mainWindow) }
        .overlay(alignment: .top) { TitlebarOverlay(workbench: workbench) }
        .overlay { TerminalDropOverlay() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { TerminalDragState.shared.workspaceFrame = $0 }
        .ignoresSafeArea(.container, edges: .top)
        // 无标题栏窗口:窗口标题仅保留给系统(Mission Control/辅助功能)。
        .navigationTitle(title)
        .onAppear { workbench.recordNavigation() }
        .onChange(of: navigationSignature) { _, _ in workbench.recordNavigation() }
    }

    /// 面板显隐动画。
    private static let panelToggleAnimation: Animation = .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.22)

    /// 当前可见的面板列(任一列显隐变化即触发动画)。
    private var panelVisibilitySignature: [PanelColumn] {
        workbench.layout.visibleColumns(on: .left) + workbench.layout.visibleColumns(on: .right)
    }

    /// 面板插入/移除的过渡:从所在侧边缘纯滑动入出(不淡入淡出,避免看起来像消失);动画绑定在过渡本身(而非事务)上,不会带动中栏逐帧重排。
    /// 「减弱动态效果」下无过渡。
    private func panelTransition(_ side: PanelSide) -> AnyTransition {
        if omShouldReduceMotion() { return .identity }
        return AnyTransition.move(edge: side == .left ? .leading : .trailing).animation(Self.panelToggleAnimation)
    }

    /// 一列面板 + 它与中栏之间的分隔条(分隔条总在靠近中栏的一侧)。
    @ViewBuilder
    private func panelColumn(_ column: PanelColumn, side: PanelSide) -> some View {
        // 宽度取「拖动中临时值,否则已提交值」:拖动期间 layout 不变,只有被拖动的这一列重新布局
        let dimension = PanelDimension(column: column)
        let width = workbench.panelDrag.effective(dimension, committed: workbench.layout)
        let defaultWidth = column == .sidebar ? PanelMetrics.leftDefault : PanelMetrics.rightDefault
        if side == .right { PanelResizer(workbench: workbench, dimension: dimension, side: side, defaultWidth: defaultWidth).zIndex(1).transition(panelTransition(side)) }
        Group {
            switch column {
            case .sidebar:
                ProjectTreeView(workbench: workbench)
                    .id(appearance.renderKey)
                    .background(SidebarBackground())
            case .tools:
                RightDockView(workbench: workbench)
            }
        }
        // 窗口放不下「面板 + 中栏最小宽度」时面板让出宽度(而不是把整个工作区撑出窗口、右上角开关被挤出可视区)
        .frame(minWidth: 0, idealWidth: CGFloat(width), maxWidth: CGFloat(width))
        .clipped()
        // 滑出时面板仍盖在(已一次性扩宽的)中栏之上,否则会被后绘制的中栏遮住而「瞬间消失」
        .zIndex(1)
        .transition(panelTransition(side))
        if side == .left { PanelResizer(workbench: workbench, dimension: dimension, side: side, defaultWidth: defaultWidth).zIndex(1).transition(panelTransition(side)) }
    }

    /// 导航历史的触发信号:聚焦组的激活标签与标签总数(关闭标签时需要清理历史)。
    private var navigationSignature: NavigationSignature {
        NavigationSignature(active: workbench.dock.focusedGroup?.activeID, tabCount: workbench.allDockTabs.count)
    }

    /// 导航历史触发信号。
    private struct NavigationSignature: Equatable {
        let active: UUID?
        let tabCount: Int
    }

    // MARK: 标题与布局

    private var title: String {
        workbench.activeSession?.sessionTitle ?? workbench.selectedEntry?.name ?? "OhMyAgent"
    }

    // MARK: 行为

    /// 窗口为 key 时,当前会话视为「正在被查看」:其未读完成状态立即清除。
    private func updateFocus() {
        AttentionCenter.shared.setFocus(windowIsKey ? workbench.activeSession?.uid : nil)
    }

    /// 响应托盘/通知发起的「打开会话」请求:仅处理属于当前项目、且连接就绪(或休眠可唤醒)时的请求。
    private func consumeSessionRequest() {
        guard let request = actions.sessionRequest, let id = workbench.selectedProjectID,
              id == URL(fileURLWithPath: request.workspacePath).standardizedFileURL.path,
              let model = workbench.activeSession, model.isAvailable else { return }
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
        // OMA_TOGGLE_RIGHT=秒 同理切换右栏;OMA_TOGGLE_COUNT=N 重复切换 N 次(间隔 1.5 秒,配合侧栏切换性能日志)
        // OMA_SWITCH_SESSIONS=N 先冷打开 N 个历史会话并在标签间切换(见 PerfBenchmarkHooks),随后才执行侧栏切换,
        // 这样侧栏开关是在「多个会话标签常驻」的真实状态下测量
        if let raw = env["OMA_SWITCH_SESSIONS"], let count = Int(raw), count > 0 {
            try? await Task.sleep(for: .seconds(env["OMA_SWITCH_DELAY"].flatMap(Double.init) ?? 3))
            await PerfBenchmarkHooks.switchSessions(workbench: workbench, count: count)
        }
        let toggleCount = env["OMA_TOGGLE_COUNT"].flatMap(Int.init) ?? 1
        for (key, toggle) in [("OMA_TOGGLE_LEFT", { workbench.toggleLeft() }), ("OMA_TOGGLE_RIGHT", { workbench.toggleRight() })] {
            guard let delay = env[key], let seconds = Double(delay) else { continue }
            try? await Task.sleep(for: .seconds(seconds))
            for _ in 0..<max(toggleCount, 1) { toggle(); try? await Task.sleep(for: .seconds(1.5)) }
        }
        // 演示模式钩子:OMA_DEMO_OPEN_SESSIONS 打开历史会话、OMA_DEMO_BENCH 运行性能基准
        await DemoLaunchHooks.run(workbench: workbench, env: env)
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
                if let prompt = model.pendingPermissions.first {
                    // 取第一个「允许」类选项(计划批准的选项 ID 不是 allow)
                    let allow = prompt.request.options.first { $0.kind == .allowOnce || $0.kind == .allowAlways }?.optionId ?? "allow"
                    model.resolve(prompt, optionId: allow)
                }
            }
        } else if env["OMA_AUTOSEND"] != nil {
            Log.app.warning("调试钩子:没有可用会话,未发送", ["active": "\(workbench.activeSession != nil)"])
        }
        if env["OMA_OPEN_PLAN"] != nil, let model = workbench.activeSession {
            // 调试:等计划文件落盘后以标签打开最近的计划(配合 OMA_AUTOALLOW 验证 Plan 标签页)
            for _ in 0..<100 where !model.timeline.entries.contains(where: { $0.planFileURL != nil }) { try? await Task.sleep(for: .milliseconds(100)) }
            if let entry = model.timeline.entries.last(where: { $0.planFileURL != nil }), let file = entry.planFileURL {
                workbench.openPlan(path: file.path, title: entry.planDocument?.name ?? String(localized: "计划"))
            }
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
        if env["OMA_OPEN_AUTOMATION"] != nil { workbench.openAutomation() }
        if let mode = env["OMA_PALETTE"] {
            // 调试:打开命令面板/快速打开,可预填查询
            PaletteModel.present(mode == "commands" ? .commands : .files, workbench: workbench)
            try? await Task.sleep(for: .milliseconds(600))
            HubModel.shared.query = env["OMA_PALETTE_QUERY"] ?? ""
        }
        if let raw = env["OMA_HUB"] {
            // 调试:打开中央搜索窗(OMA_HUB=all|sessions|projects|files|actions|settings),可用 OMA_HUB_QUERY 预填查询
            HubModel.shared.present(HubSegment(rawValue: raw) ?? .all, workbench: workbench, query: env["OMA_HUB_QUERY"] ?? "")
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
        // 调试:资源管理器拖放(OMA_EXPLORER_DROP=<目标文件夹>|<源1>|<源2>…,走与真实拖放相同的移动/复制流程)
        if let spec = env["OMA_EXPLORER_DROP"], !spec.isEmpty {
            let parts = spec.split(separator: "|").map(String.init)
            if parts.count >= 2 {
                try? await Task.sleep(for: .milliseconds(1500))
                ExplorerActions.perform(sources: Array(parts.dropFirst()), into: parts[0], workbench: workbench)
            }
        }
        // 调试:面板摆放(OMA_SIDEBAR_SIDE/OMA_TOOLS_SIDE=left|right)、OMA_SHOW_TERMINAL=1(右栏开终端标签)、OMA_SHOW_OUTPUT=1(右栏开输出标签)
        if let value = env["OMA_SIDEBAR_SIDE"].flatMap(PanelSide.init(rawValue:)) { workbench.setSidebarSide(value) }
        if let value = env["OMA_TOOLS_SIDE"].flatMap(PanelSide.init(rawValue:)) { workbench.setToolsSide(value) }
        if env["OMA_SHOW_TERMINAL"] != nil { workbench.showTerminal() }
        // 调试:OMA_TERMINAL_NAMES=构建,服务,日志 —— 给当前项目预置多个命名终端(第一个重命名已有终端,其余新建)
        if let names = env["OMA_TERMINAL_NAMES"]?.split(separator: ",").map(String.init), let first = names.first {
            let root = workbench.selectedProjectID ?? NSHomeDirectory()
            TerminalPanelStore.shared.rename(TerminalPanelState.baseID(root), to: first, root: root)
            let existing = Set(TerminalPanelStore.shared.state(for: root).instances.compactMap(\.customTitle))  // 重复启动不重复新建
            for name in names.dropFirst() where !existing.contains(name) { TerminalPanelStore.shared.addTerminal(root: root, name: name) }
            TerminalPanelStore.shared.activate(TerminalPanelState.baseID(root), root: root)
        }
        if let ms = env["OMA_CYCLE_TERMINALS"].flatMap(Int.init) {
            // 调试(性能采样):给每个终端灌 3000 行输出后,每 ms 毫秒循环切换一次终端,持续约 20 秒
            let root = workbench.selectedProjectID ?? NSHomeDirectory()
            for _ in 0..<TerminalPanelStore.shared.state(for: root).instances.count {
                TerminalStore.shared.controllers.values.forEach { $0.send("seq 1 3000\r") }
                TerminalPanelStore.shared.cycle(1, root: root)
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<(20_000 / max(ms, 50)) {
                TerminalPanelStore.shared.cycle(1, root: root)
                try? await Task.sleep(for: .milliseconds(max(ms, 50)))
            }
        }
        if env["OMA_VIEW_AGENT_TERMINAL"] != nil {
            // 调试:等到出现运行中的 Agent 终端后,在终端面板里只读打开它(验证后台命令的实时查看)
            for _ in 0..<60 {
                let found = workbench.conversations.values.lazy.compactMap { model in model.terminals.values.first(where: \.isRunning).map { (model, $0) } }.first
                if let (model, session) = found { actions.viewAgentTerminal(session, model: model); break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if env["OMA_SHOW_RIGHT"] != nil { workbench.layout.rightVisible = true }
        if env["OMA_SHOW_OUTPUT"] != nil { workbench.showOutput(); workbench.layout.rightVisible = true }
        if env["OMA_OPEN_SETTINGS"] != nil {
            workbench.openSettings()
        }
        // 调试:OMA_OPEN_CUSTOMIZE=all|plugins|skills|commands|subagents|rules|mcp|hooks 直接打开「自定义」页
        // 调试:OMA_OPEN_CANVAS=<画布 id> 直接打开画布标签
        if let canvasID = env["OMA_OPEN_CANVAS"], !canvasID.isEmpty { workbench.openCanvas(id: canvasID, title: String(localized: "画布")) }
        if let filter = env["OMA_OPEN_CUSTOMIZE"] { workbench.openCustomize(filter: filter) }
        // 调试:OMA_OPEN_BROWSER=<网址> 在浏览器标签里打开页面
        if let raw = env["OMA_OPEN_BROWSER"], let url = BrowserArguments.normalize(raw), let workspace = workbench.selectedProjectID {
            Task {
                let first = await BrowserController.shared.run(.navigate(url: url), workspace: workspace, activate: true)
                // 调试:OMA_BROWSER_PROBE=<输出文件> + OMA_BROWSER_ACTIONS 在导航后按顺序执行浏览器命令并记录结果
                if let output = env["OMA_BROWSER_PROBE"], let actions = env["OMA_BROWSER_ACTIONS"] {
                    await BrowserProbe.run(output: output, actions: actions, workspace: workspace)
                    _ = first
                }
            }
        }
        // 调试(流畅度基准):OMA_RESIZE_SWEEP / OMA_DRAG_SWEEP / OMA_SCROLL_SWEEP,见 ResizeBenchmarkHooks
        await ResizeBenchmarkHooks.runIfRequested(env: env, workbench: workbench)
        // 启动稍后按间隔检查一次工作树数量(超限时询问是否清理;演示模式不触发)
        if env["OMA_DEMO"] == nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                WorktreeActions.periodicCleanup()
            }
        }
    }
}

/// 中栏:停靠区(标签组与分屏)。
struct CenterColumn: View {
    @Bindable var workbench: WorkbenchModel
    private let appearance = AppearanceModel.shared

    var body: some View {
        let _ = PanelToggleProbe.count("center")
        VStack(spacing: 0) {
            DockView(workbench: workbench)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 主题/强调色变化时整体重建,令牌颜色立即生效(终端进程由 TerminalStore 持有,不受影响)
        .id(appearance.themeRevision)
        .onChange(of: pendingViewerRequest) { _, request in
            // 统一打开入口:工具行/Bridge/改动汇总发出的「查看文件」请求都变成文件标签
            guard let request, let model = workbench.allSessions.first(where: { $0.viewerRequest == request }) else { return }
            model.viewerRequest = nil
            workbench.openFile(request.path, line: request.line)
        }
        .onChange(of: pendingCanvasRequest) { _, request in
            // Agent 通过 Bridge 新建画布 → 在标签页中打开
            guard let request, let model = workbench.allSessions.first(where: { $0.canvasRequest == request }) else { return }
            model.canvasRequest = nil
            workbench.openCanvas(id: request.canvasID, title: request.title)
        }
    }

    /// 任一会话中待处理的画布打开请求。
    private var pendingCanvasRequest: CanvasOpenRequest? {
        workbench.allSessions.lazy.compactMap(\.canvasRequest).first
    }

    /// 任一会话中待处理的文件查看请求。
    private var pendingViewerRequest: FileViewRequest? {
        workbench.allSessions.lazy.compactMap(\.viewerRequest).first
    }
}
