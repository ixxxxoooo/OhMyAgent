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
