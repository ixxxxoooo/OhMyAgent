// @author ixxxxoooo
// 工作台通用部件:Agent 菜单、用量环与用量按钮、窗口焦点读取。

import IconKit
import ACPKit
import AgentHost
import ChatKit
import DesignSystem
import OMLog
import SwiftUI

/// Agent 切换菜单:列出已启用的 Agent,切换会在当前项目开始新会话。
/// 显示当前 Agent 名称(输入区页脚右侧);切换逻辑内置,不依赖外部闭包。
struct AgentMenu: View {
    let model: SessionModel
    private let registry = AgentRegistryModel.shared

    @State private var shown = false

    private var entries: [PickEntry] {
        registry.data.enabledAgents.map { PickEntry(id: $0.id, title: $0.name, icon: "bot") }
            + [PickEntry(id: Self.manageID, title: String(localized: "管理 Agent…"), group: String(localized: "更多"), icon: "settings")]
    }

    private static let manageID = "__manage__"

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Image.om("bot", size: 12)
                Text(model.descriptor.name).lineLimit(1)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .omTooltip(String(localized: "切换 Agent(会在当前项目开始新会话),当前:\(model.descriptor.name)"))
        .accessibilityLabel("切换 Agent")
        .onChange(of: shown) { _, isShown in
            // 打开引擎选择器时预热其余引擎:选中后几乎立即可用
            if isShown { AppEnvironment.shared.warmOtherEngines(current: model) }
        }
        .omPicker(isPresented: $shown, entries: entries, selectedID: model.descriptor.id, placeholder: String(localized: "搜索 Agent"), width: 220) { entry in
            if entry.id == Self.manageID {
                AppActions.shared.openSettings(page: .agentExtensions)
            } else if let agent = registry.data.enabledAgents.first(where: { $0.id == entry.id }) {
                Self.switchAgent(to: agent)
            }
        }
    }

    /// 当前项目内切换 Agent。
    /// - 当前会话还是空白:原位替换成新引擎的空白会话(列表不变)。
    /// - 当前会话已有内容:保持它原样不动,在新标签里用新引擎开始新对话——
    ///   切换引擎不会让任何已有会话发生变化或消失。
    /// - Parameter descriptor: 目标 Agent
    @MainActor
    static func switchAgent(to descriptor: AgentDescriptor) {
        let workbench = AppEnvironment.shared.workbench
        guard let id = workbench.selectedProjectID, let current = workbench.activeSession, descriptor.id != current.descriptor.id else { return }
        Log.session.info("切换 Agent", ["project": id, "from": current.descriptor.id, "to": descriptor.id, "pristine": current.isPristine ? "yes" : "no"])
        guard current.isPristine else {
            workbench.newConversation(in: id, agentID: descriptor.id)
            return
        }
        // 优先认领预热好的待命会话,没有再现场创建
        let project = workbench.projects.first(where: { $0.id == id })
        let next = project.flatMap { workbench.takeWarmSession(agentID: descriptor.id, project: $0) }
            ?? AppEnvironment.makeSession(workspace: current.workspace, descriptor: descriptor)
        workbench.replaceSession(for: id, with: next)
    }
}

/// 上下文用量环:无数据时为虚线轨道,有数据时画进度弧,高占用依次变为警告色/危险色。
struct UsageRing: View {
    /// 占用比例(0...1);nil 表示尚无数据
    let fraction: Double?

    /// 有占用但很小时进度弧至少显示的比例,避免低占用时看起来像「没有数据」。
    private static let minVisible = 0.04

    private var tone: Color {
        switch ContextTone(fraction: fraction ?? 0) {
        case .normal: return OMColors.secondaryText
        case .warn: return OMColors.warning
        case .danger: return OMColors.danger
        }
    }

    var body: some View {
        let shown = fraction.map { $0 > 0 ? max(min($0, 1), Self.minVisible) : 0 } ?? 0
        ZStack {
            Circle().stroke(OMColors.hairline, style: StrokeStyle(lineWidth: 2.2, dash: fraction == nil ? [2, 2] : []))
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tone, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// 用量按钮(输入区页脚):圆环显示上下文占用,点击展开/收起输入区上方的「上下文用量」面板。
struct UsageButton: View {
    let model: SessionModel
    @Binding var isOpen: Bool

    /// 圆环使用的占用比例:优先 Agent 实时上报,其次 `/context` 明细。
    private var fraction: Double? {
        ContextUsage(reported: model.usage ?? UsageUpdate())?.fraction ?? model.contextUsage?.fraction
    }

    var body: some View {
        Button { omWithAnimation { isOpen.toggle() } } label: {
            // 圆环本身只有 2pt 描边可命中;整块矩形都要可点,否则点圆心或空隙没有反应
            UsageRing(fraction: fraction)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .omTooltip(fraction.map { String(localized: "上下文 \(Int(($0 * 100).rounded()))%") } ?? String(localized: "上下文用量"))
        .accessibilityLabel("上下文用量")
        .accessibilityValue(fraction.map { String(localized: "已使用 \(Int(($0 * 100).rounded()))%") } ?? String(localized: "暂无数据"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
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
