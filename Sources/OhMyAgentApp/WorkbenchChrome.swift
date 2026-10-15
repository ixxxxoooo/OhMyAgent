// @author ygw
// 工作台通用部件:窗口工具栏、Agent 菜单、连接徽标、用量环与用量按钮、窗口焦点读取。

import IconKit
import ACPKit
import AgentHost
import ChatKit
import DesignSystem
import SwiftUI

/// Agent 切换菜单:列出已启用的 Agent,切换会在当前窗口开始新会话。
struct AgentMenu: View {
    let model: SessionModel
    let switchAgent: (AgentDescriptor) -> Void
    private let registry = AgentRegistryModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(registry.data.enabledAgents) { agent in
                Button {
                    switchAgent(agent)
                } label: {
                    if agent.id == model.descriptor.id { Label(agent.name, om: "checkmark") } else { Text(agent.name) }
                }
            }
            Divider()
            Button("管理 Agent…") {
                SettingsRouter.shared.go(.agentExtensions)
                openSettings()
            }
        } label: {
            Label(model.descriptor.name, om: "person.crop.rectangle.stack")
        }
        .menuIndicator(.visible)
        .help("切换 Agent(会在当前项目开始新会话)")
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
            if usage.size != nil { UsageRing(fraction: fraction) } else { Image.om("gauge.with.needle") }
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
                        Label("已超过预算提醒阈值", om: "exclamationmark.triangle.fill").font(OMFonts.small).foregroundStyle(OMColors.warning)
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
    var onWindow: ((NSWindow) -> Void)?
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = FocusView()
        view.onChange = onChange
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FocusView)?.onChange = onChange
    }

    private final class FocusView: NSView {
        var onChange: ((Bool) -> Void)?
        var onWindow: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            onWindow?(window)
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

extension URL {
    /// 以 `~` 缩写主目录的路径展示。
    var abbreviatingHome: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
