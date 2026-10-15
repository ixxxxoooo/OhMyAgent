// @author ygw
// 工作区窗口:玻璃侧栏 + 时间线 + 浮动输入区。

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
        .navigationTitle(model.sessionTitle ?? workspace.lastPathComponent)
        .navigationSubtitle(workspace.abbreviatingHome)
        .toolbar { WindowToolbar(model: model) }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            WorkspaceStore.remember(workspace)
            SessionRegistry.shared.register(model)
            // 首帧之后后台预热连接,首次发送时通常已就绪
            model.connect()
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
            if let usage = model.usage, let used = usage.used, let size = usage.size, size > 0 {
                UsageRing(fraction: Double(used) / Double(size))
                    .help("上下文已用 \(used) / \(size) tokens")
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
