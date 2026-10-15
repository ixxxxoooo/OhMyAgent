// @author ygw
// 工作区窗口:玻璃侧栏 + 时间线 + 浮动输入区。

import ACPKit
import AgentHost
import ChatKit
import DesignSystem
import SwiftUI

/// 工作区窗口根视图。
struct WorkspaceWindow: View {
    let workspace: URL
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let appearance = AppearanceModel.shared
    @State private var model: SessionModel
    private let actions = AppActions.shared

    /// - Parameter workspace: 工作区目录
    init(workspace: URL) {
        self.workspace = workspace
        _model = State(initialValue: Self.makeModel(workspace: workspace, descriptor: Toolchain.defaultDescriptor()))
    }

    /// 创建会话模型并接入应用层能力(系统通知)。
    static func makeModel(workspace: URL, descriptor: AgentDescriptor) -> SessionModel {
        let model = SessionModel(workspace: workspace, descriptor: descriptor)
        model.notifier = { title, message in AppNotifier.send(title: title, message: message) }
        return model
    }

    /// 响应托盘/通知发起的「打开会话」请求:仅处理属于本工作区、且连接就绪时的请求。
    private func consumeSessionRequest() {
        guard let request = actions.sessionRequest, request.workspacePath == workspace.path, model.phase == .ready else { return }
        actions.sessionRequest = nil
        AttentionCenter.shared.markRead(model.uid)
        guard let sessionId = request.sessionId, sessionId != model.sessionId else { return }
        let summary = model.history.first { $0.sessionId == sessionId }
            ?? SessionSummary(sessionId: sessionId, cwd: workspace.path, title: request.title, updatedAt: nil)
        model.openSession(summary)
    }

    /// 窗口内切换 Agent:结束旧会话进程,用新描述符开始新会话。
    private func switchAgent(to descriptor: AgentDescriptor) {
        guard descriptor.id != model.descriptor.id else { return }
        model.shutdown()
        SessionRegistry.shared.unregister(model)
        let next = Self.makeModel(workspace: workspace, descriptor: descriptor)
        model = next
        SessionRegistry.shared.register(next)
        next.connect()
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .id(appearance.fontRevision)
                .navigationSplitViewColumnWidth(min: 200, ideal: OMMetrics.sidebarWidth, max: 340)
        } detail: {
            // 字号变化时重建视图树以刷新字体令牌;会话状态在 model 中,不受影响
            ChatView(model: model)
                .id(appearance.fontRevision)
        }
        .tint(appearance.accent.color)
        .environment(model)
        .sheet(item: $model.viewerRequest) { request in
            FileViewerSheet(request: request)
        }
        .navigationTitle(model.sessionTitle ?? model.workspace.lastPathComponent)
        .navigationSubtitle(model.workspace.abbreviatingHome)
        .toolbar { WindowToolbar(model: model, switchAgent: switchAgent) }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowFocusReader { focused in
            AttentionCenter.shared.setFocus(focused ? model.uid : (AttentionCenter.shared.focusedID == model.uid ? nil : AttentionCenter.shared.focusedID))
        })
        .onAppear {
            DiagnosticsStore.shared.markFirstFrame()
            actions.capture(openWindow: openWindow, openSettings: openSettings)
        }
        .onChange(of: model.phase) { _, _ in consumeSessionRequest() }
        .onChange(of: actions.sessionRequest) { _, _ in consumeSessionRequest() }
        .task {
            WorkspaceStore.remember(workspace)
            SessionRegistry.shared.register(model)
            // 首帧之后后台预热连接,首次发送时通常已就绪
            model.connect()
            // 调试钩子:预置输入框内容(用于不抢焦点的界面验证)
            if let draft = ProcessInfo.processInfo.environment["OMA_DRAFT"], !draft.isEmpty { model.draft = draft }
            // 调试钩子:连接就绪后自动发送一条消息(用于验证运行中/未读状态点)
            if let text = ProcessInfo.processInfo.environment["OMA_AUTOSEND"], !text.isEmpty {
                for _ in 0..<100 where model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
                model.send(text)
            }
            if ProcessInfo.processInfo.environment["OMA_OPEN_EXTENSIONS"] != nil { openWindow(id: "extensions", value: workspace) }
            if ProcessInfo.processInfo.environment["OMA_OPEN_SETTINGS"] != nil {
                openSettings()
                // 调试:不激活应用,仅把窗口置前,避免被遮挡时视图停止刷新
                try? await Task.sleep(for: .milliseconds(600))
                for window in NSApp.windows where window.title != "OhMyAgent" && !window.title.isEmpty { window.orderFrontRegardless() }
            }
        }
        .onDisappear {
            model.shutdown()
            SessionRegistry.shared.unregister(model)
        }
    }
}

extension URL {
    /// 以 `~` 缩写主目录的路径展示。
    var abbreviatingHome: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// 窗口工具栏:连接状态、用量、新对话。
struct WindowToolbar: ToolbarContent {
    let model: SessionModel
    let switchAgent: (AgentDescriptor) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            AgentMenu(model: model, switchAgent: switchAgent)
        }
        ToolbarItem(placement: .primaryAction) {
            ConnectionBadge(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            if let usage = model.usage, usage.used != nil || usage.costAmount != nil {
                UsageButton(usage: usage)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "extensions", value: model.workspace) } label: {
                Label("扩展管理", systemImage: "puzzlepiece.extension")
            }
            .help("MCP、Skills、子 Agent、Hooks、插件与记忆 (⇧⌘E)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.newConversation()
            } label: {
                Label("新对话", systemImage: "square.and.pencil")
            }
            .help("新对话 (⌘N)")
            .keyboardShortcut(ShortcutStore.shared.shortcut(for: .newConversation))
            .disabled(model.phase != .ready)
        }
    }
}

/// Agent 切换菜单:列出已启用的 Agent,切换会在当前窗口开始新会话。
struct AgentMenu: View {
    let model: SessionModel
    let switchAgent: (AgentDescriptor) -> Void
    private let registry = AgentRegistryModel.shared

    var body: some View {
        Menu {
            ForEach(registry.data.enabledAgents) { agent in
                Button {
                    switchAgent(agent)
                } label: {
                    if agent.id == model.descriptor.id { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                }
            }
            Divider()
            SettingsLink { Text("管理 Agent…") }
        } label: {
            Label(model.descriptor.name, systemImage: "person.crop.rectangle.stack")
        }
        .menuIndicator(.visible)
        .help("切换 Agent(会在此窗口开始新会话)")
    }
}

/// 连接状态徽标。
struct ConnectionBadge: View {
    let model: SessionModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .idle:
                OMStatusDot(.idle)
                Text("未连接")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("正在连接…")
            case .ready:
                OMStatusDot(model.isRunning ? .running : .success)
                Text(model.isRunning ? "工作中" : model.agentName)
            case .failed:
                OMStatusDot(.failure)
                Text("连接失败")
            }
        }
        .font(OMFonts.small)
        .foregroundStyle(OMColors.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

/// 上下文用量环。
struct UsageRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(OMColors.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(fraction > 0.9 ? Color.red : fraction > 0.7 ? OMColors.warning : OMColors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel("上下文用量 \(Int(fraction * 100))%")
    }
}

/// 用量按钮:点击弹出上下文占用与费用详情。
struct UsageButton: View {
    let usage: UsageUpdate
    @State private var shown = false

    /// 费用是否超过设置页中的预算阈值(阈值为 0 表示关闭)。
    private func overBudget(_ cost: Double) -> Bool {
        let budget = ClientPrefs.budgetUSD()
        return budget > 0 && cost >= budget
    }

    private var fraction: Double {
        guard let used = usage.used, let size = usage.size, size > 0 else { return 0 }
        return Double(used) / Double(size)
    }

    var body: some View {
        Button { shown.toggle() } label: {
            if usage.size != nil { UsageRing(fraction: fraction) } else { Image(systemName: "gauge.with.needle") }
        }
        .help("用量详情")
        .accessibilityLabel("用量详情")
        .accessibilityValue(usage.size != nil ? "上下文已使用 \(Int(fraction * 100))%" : "暂无数据")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("会话用量").font(OMFonts.title)
                if let used = usage.used {
                    if let size = usage.size, size > 0 {
                        ProgressView(value: min(fraction, 1))
                        Text("上下文 \(used.formatted()) / \(size.formatted()) tokens(\(Int(fraction * 100))%)").font(OMFonts.small)
                    } else {
                        Text("已用 \(used.formatted()) tokens").font(OMFonts.small)
                    }
                }
                if let cost = usage.costAmount {
                    Text("累计费用 \(cost.formatted(.number.precision(.fractionLength(2...4)))) \(usage.costCurrency ?? "USD")").font(OMFonts.small)
                    if overBudget(cost) {
                        Label("已超过预算提醒阈值", systemImage: "exclamationmark.triangle.fill").font(OMFonts.small).foregroundStyle(OMColors.warning)
                    }
                }
                Text("数据来自 Agent 上报,订阅账号可能不显示费用。")
                    .font(OMFonts.caption)
                    .foregroundStyle(OMColors.secondaryText)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
    }
}


/// 读取宿主窗口的 key 状态:窗口成为 key 时回调 true,失去时回调 false。
struct WindowFocusReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FocusView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FocusView)?.onChange = onChange
    }

    private final class FocusView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(true) }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(false) }
            })
            if window.isKeyWindow { onChange?(true) }
        }
    }
}
