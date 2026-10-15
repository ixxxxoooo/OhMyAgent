// @author ygw
// 工作区窗口:玻璃侧栏 + 时间线 + 浮动输入区。

import ACPKit
import ChatKit
import DesignSystem
import SwiftUI

/// 工作区窗口根视图。
struct WorkspaceWindow: View {
    let workspace: URL
    @State private var model: SessionModel

    /// - Parameter workspace: 工作区目录
    init(workspace: URL) {
        self.workspace = workspace
        _model = State(initialValue: SessionModel(workspace: workspace))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: OMMetrics.sidebarWidth, max: 340)
        } detail: {
            ChatView(model: model)
        }
        .environment(model)
        .sheet(item: $model.viewerRequest) { request in
            FileViewerSheet(request: request)
        }
        .navigationTitle(model.sessionTitle ?? model.workspace.lastPathComponent)
        .navigationSubtitle(model.workspace.abbreviatingHome)
        .toolbar { WindowToolbar(model: model) }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            WorkspaceStore.remember(workspace)
            SessionRegistry.shared.register(model)
            // 首帧之后后台预热连接,首次发送时通常已就绪
            model.connect()
            // 调试钩子:预置输入框内容(用于不抢焦点的界面验证)
            if let draft = ProcessInfo.processInfo.environment["OMA_DRAFT"], !draft.isEmpty { model.draft = draft }
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

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ConnectionBadge(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            if let usage = model.usage, usage.used != nil || usage.costAmount != nil {
                UsageButton(usage: usage)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.newConversation()
            } label: {
                Label("新对话", systemImage: "square.and.pencil")
            }
            .help("新对话 (⌘N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.phase != .ready)
        }
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

    private var fraction: Double {
        guard let used = usage.used, let size = usage.size, size > 0 else { return 0 }
        return Double(used) / Double(size)
    }

    var body: some View {
        Button { shown.toggle() } label: {
            if usage.size != nil { UsageRing(fraction: fraction) } else { Image(systemName: "gauge.with.needle") }
        }
        .help("用量详情")
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
