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
        .help(help)
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
            .background(tint.opacity(0.12), in: Capsule())
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
