// @author ixxxxoooo
// 基础组件:图标按钮、状态点、标签。

import IconKit
import SwiftUI

/// 玻璃图标按钮,用于工具栏与浮动操作条。
public struct OMIconButton: View {
    private let symbol: String
    private let help: String
    private let action: () -> Void

    /// 创建按钮。
    /// - Parameters:
    ///   - symbol: 图标语义名或 Lucide 名
    ///   - help: 悬停提示与辅助功能标签
    ///   - action: 点击回调
    public init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image.om(symbol, size: 15)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .omGlass(in: Circle(), interactive: true)
        .omTooltip(help)
        .accessibilityLabel(help)
    }
}

/// 状态点。
public struct OMStatusDot: View {
    public enum State: Sendable { case idle, running, success, failure, warning }
    private let state: State

    public init(_ state: State) { self.state = state }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .idle: return OMColors.tertiaryText
        case .running: return OMColors.accent
        case .success: return OMColors.success
        case .failure: return OMColors.danger
        case .warning: return OMColors.warning
        }
    }
}

/// 小标签(胶囊,纯色)。
public struct OMTag: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color = OMColors.secondaryText) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(OMFonts.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: OMPillShape())
    }
}

// MARK: - 空状态

/// 空状态标签样式:图标在上(三级文字色)、标题在下(`sectionTitle`)。
struct OMEmptyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            configuration.icon.foregroundStyle(OMColors.tertiaryText)
            configuration.title.font(OMFonts.sectionTitle).foregroundStyle(OMColors.primaryText)
        }
    }
}

/// 统一的空状态视图:取代系统 `OMEmptyState`(其标题字号过大、不跟随界面字号与主题)。
/// 标题用 `sectionTitle`,说明用 `small` + 次要文字色,操作按钮统一 `omSecondary`。
public struct OMEmptyState<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let descriptionView: Description
    private let actions: Actions

    /// 创建空状态。
    /// - Parameters:
    ///   - label: 图标 + 标题(一般为 `Label(_:om:size:)`)
    ///   - description: 说明文字
    ///   - actions: 可选操作按钮
    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() },
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label()
        self.descriptionView = description()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 10) {
            label.labelStyle(OMEmptyLabelStyle())
            descriptionView
                .font(OMFonts.small)
                .foregroundStyle(OMColors.secondaryText)
                .multilineTextAlignment(.center)
            actions.buttonStyle(.omSecondary)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// 会话状态点的种类。
public enum OMSessionDotKind: Sendable {
    /// 运行中:实心点,缓慢呼吸
    case running
    /// 等待处理:空心环,稍慢呼吸
    case waiting
    /// 已完成未读:静止实心点
    case unread
    /// 空闲:灰点
    case idle
}

/// 会话状态点:颜色取主题强调色(`OMColors.statusActive` 系列),不同状态靠形状与节奏区分;
/// 运行/等待用「呼吸」(透明度 + 缩放缓慢渐变),遵循「减弱动态效果」。
public struct OMSessionDot: View {
    private let kind: OMSessionDotKind
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - kind: 状态种类
    ///   - size: 点的直径
    public init(_ kind: OMSessionDotKind, size: CGFloat = 7) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        Group {
            switch kind {
            case .running: breathing(shape(fill: OMColors.statusRunning), duration: 0.6)
            case .waiting: breathing(shape(ring: OMColors.statusWaiting), duration: 0.9)
            case .unread: shape(fill: OMColors.statusUnread).frame(width: size * 0.85, height: size * 0.85)
            case .idle: shape(fill: OMColors.statusIdle)
            }
        }
        .frame(width: size, height: size)
    }

    private func shape(fill color: Color) -> some View { Circle().fill(color) }

    private func shape(ring color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: max(1.4, size * 0.2))
    }

    /// 呼吸:单程 `duration` 秒,往复一周期 = 2 × duration。
    @ViewBuilder
    private func breathing<V: View>(_ view: V, duration: Double) -> some View {
        if reduceMotion || omShouldReduceMotion() {
            view
        } else {
            view.phaseAnimator([false, true]) { content, expanded in
                content.opacity(expanded ? 1 : 0.4).scaleEffect(expanded ? 1 : 0.78)
            } animation: { _ in .easeInOut(duration: duration) }
        }
    }
}

/// 加载转圈:弧线颜色固定取主题强调色(系统 `ProgressView` 不跟随 tint),遵循「减弱动态效果」。
public struct OMSpinner: View {
    public enum Size: Sendable {
        case mini, small, regular
        var points: CGFloat {
            switch self {
            case .mini: return 12
            case .small: return 16
            case .regular: return 24
            }
        }
    }

    private let size: Size
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ size: Size = .regular) { self.size = size }

    public var body: some View {
        let diameter = size.points
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(OMColors.statusActive, style: StrokeStyle(lineWidth: max(1.5, diameter / 8), lineCap: .round))
            .frame(width: diameter - 2, height: diameter - 2)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .frame(width: diameter, height: diameter)
            .onAppear {
                guard !(reduceMotion || omShouldReduceMotion()) else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityLabel("加载中")
    }
}
