// @author ixxxxoooo
// 统一 UI 控件:按钮样式、复制按钮、档位滑块。
// 全应用的按钮 / 复制 / 档位选择都走这里,禁止再用系统 `.bordered`、`.borderedProminent`、手写复制图标
// (`Scripts/ui-lint.py` 在 CI 中扫描违规)。规范全文见 AGENTS.md「4.2 UI 组件与字号规范」。

import AppKit
import IconKit
import SwiftUI

/// 统一按钮样式。七种风格 × 两种尺寸,颜色全部取自 `OMColors`,随主题变化。
/// 纸感规范(AGENTS.md 4.4):主按钮墨色实底、次按钮 Linen 底(墨色 8%)、plain 幽灵悬停出现下划线;
/// 同一组动作最多两种实心(主 + 次,或主 + 幽灵),不叠三个实心按钮。
public struct OMButtonStyle: ButtonStyle {
    /// 风格。
    public enum Kind: Sendable {
        /// 主操作:纸感为墨色实底,其他主题为强调色实底
        case primary
        /// 次操作:浅底(纸感无描边,其他主题带细描边)
        case secondary
        /// 无底文字按钮:仅悬停出现底色(纸感:60% 文字,悬停下划线)
        case plain
        /// 破坏性操作:危险色文字 + 浅底
        case destructive
        /// 仅图标:方形,悬停出现底色
        case icon
        /// 暖色动作(继续、执行计划):Amber 实底
        case warm
        /// 正向动作(提交、创建 PR):Forest 实底
        case positive
    }

    /// 尺寸:紧凑 24pt、常规 28pt。
    public enum Size: Sendable {
        case compact, regular

        /// 控件高度。
        public var height: CGFloat { self == .compact ? 24 : 28 }
    }

    private let kind: Kind
    private let size: Size

    /// - Parameters:
    ///   - kind: 风格
    ///   - size: 尺寸,默认紧凑(设置页与工具条的默认密度)
    public init(_ kind: Kind, size: Size = .compact) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        OMButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

/// 按钮外观(拆成独立视图以便读取 `isEnabled` 与悬停状态)。
private struct OMButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: OMButtonStyle.Kind
    let size: OMButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    /// 纸感的扁平按钮风格(次按钮无描边、文字按钮悬停加下划线);与主按钮填充色无关。
    private var inkStyle: Bool { ThemeRuntime.style.flatCards }

    var body: some View {
        configuration.label
            .font(size == .compact ? OMFonts.small : OMFonts.body)
            .foregroundStyle(foreground)
            .underline(kind == .plain && inkStyle && hovering && isEnabled)
            .padding(.horizontal, kind == .icon ? 0 : (size == .compact ? 9 : 12))
            .frame(minWidth: kind == .icon ? size.height : nil, minHeight: size.height)
            .frame(height: size.height)
            .background(background, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .onHover { hovering = $0 }
            .animation(OMMotion.standard, value: hovering)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size == .compact ? OMRadius.tag : OMRadius.control, style: .continuous)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return OMColors.onAction
        case .warm: return OMColors.onWarm
        case .positive: return OMColors.onPositive
        case .plain: return inkStyle && !(hovering && isEnabled) ? OMColors.primaryText.opacity(0.6) : OMColors.primaryText
        case .secondary, .icon: return OMColors.primaryText
        case .destructive: return OMColors.danger
        }
    }

    private var background: Color {
        let active = hovering && isEnabled
        switch kind {
        case .primary: return active ? OMColors.actionFill.opacity(0.88) : OMColors.actionFill
        case .warm: return active ? OMColors.actionWarm.opacity(0.88) : OMColors.actionWarm
        case .positive: return active ? OMColors.actionPositive.opacity(0.88) : OMColors.actionPositive
        case .secondary:
            // 纸感:Linen 底(墨色 8%),悬停加深;其他主题保持浅底
            if inkStyle { return OMColors.primaryText.opacity(active ? 0.12 : 0.08) }
            return OMColors.primaryText.opacity(active ? 0.10 : 0.05)
        case .destructive: return OMColors.danger.opacity(active ? 0.16 : 0.09)
        case .plain: return inkStyle ? .clear : OMColors.primaryText.opacity(active ? 0.08 : 0)
        case .icon: return OMColors.primaryText.opacity(active ? 0.08 : 0)
        }
    }

    private var border: Color {
        switch kind {
        case .secondary: return inkStyle ? .clear : OMColors.hairline.opacity(0.7)
        default: return .clear
        }
    }
}

extension ButtonStyle where Self == OMButtonStyle {
    /// 主操作按钮(紧凑)。
    public static var omPrimary: OMButtonStyle { OMButtonStyle(.primary) }
    /// 次操作按钮(紧凑)。
    public static var omSecondary: OMButtonStyle { OMButtonStyle(.secondary) }
    /// 无底文字按钮(紧凑)。
    public static var omPlain: OMButtonStyle { OMButtonStyle(.plain) }
    /// 破坏性按钮(紧凑)。
    public static var omDestructive: OMButtonStyle { OMButtonStyle(.destructive) }
    /// 仅图标按钮。
    public static var omIcon: OMButtonStyle { OMButtonStyle(.icon) }
    /// 暖色动作按钮(继续、执行计划),Amber 实底。
    public static var omWarm: OMButtonStyle { OMButtonStyle(.warm) }
    /// 正向动作按钮(提交、创建 PR),Forest 实底。
    public static var omPositive: OMButtonStyle { OMButtonStyle(.positive) }
}

/// 复制按钮:仅图标(`copy`),复制成功后短暂变为 `check`。规范要求界面里的复制按钮一律用它。
public struct OMCopyButton: View {
    private let help: String
    private let size: CGFloat
    private let text: () -> String?
    @State private var copied = false

    /// - Parameters:
    ///   - help: 悬停提示与辅助功能标签(例如「复制本轮输出」)
    ///   - size: 图标尺寸
    ///   - text: 取要复制的文本;返回 nil 或空串时不写剪贴板
    public init(help: String, size: CGFloat = 13, text: @escaping () -> String?) {
        self.help = help
        self.size = size
        self.text = text
    }

    public var body: some View {
        Button {
            guard let value = text(), !value.isEmpty else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image.om(copied ? "check" : "copy", size: size)
                .foregroundStyle(copied ? OMColors.success : OMColors.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? String(localized: "已复制") : help)
        .accessibilityLabel(help)
    }
}

/// 档位滑块:带刻度、吸附到离散档位的横向滑块,替代下拉选择。
/// 档位较少(≤5)时刻度下方显示全部名称,较多时只显示首尾。
public struct OMStepSlider: View {
    private let stops: [String]
    private let index: Binding<Int>
    private let accessibilityName: String

    /// - Parameters:
    ///   - stops: 各档位显示名(从左到右)
    ///   - index: 当前档位下标(越界时按边界处理)
    ///   - accessibilityName: 无障碍标签
    public init(stops: [String], index: Binding<Int>, accessibilityName: String) {
        self.stops = stops
        self.index = index
        self.accessibilityName = accessibilityName
    }

    private var lastIndex: Int { max(stops.count - 1, 0) }
    private var current: Int { min(max(index.wrappedValue, 0), lastIndex) }
    private let thumb: CGFloat = 14

    public var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let travel = max(proxy.size.width - thumb, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(OMColors.pressedFill).frame(height: 4).padding(.horizontal, thumb / 2) // ui-lint:allow 滑块轨道几何
                    Capsule().fill(OMColors.actionFill) // ui-lint:allow 滑块轨道几何
                        .frame(width: travel * fraction(current), height: 4)
                        .padding(.leading, thumb / 2)
                    ForEach(0..<stops.count, id: \.self) { tick in
                        Circle()
                            .fill(tick <= current ? OMColors.onAction.opacity(0.9) : OMColors.tertiaryText)
                            .frame(width: 3, height: 3)
                            .offset(x: thumb / 2 + travel * fraction(tick) - 1.5)
                    }
                    Circle()
                        .fill(OMColors.card)
                        .overlay(Circle().strokeBorder(OMColors.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .frame(width: thumb, height: thumb)
                        .offset(x: travel * fraction(current))
                }
                .frame(height: thumb)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        guard lastIndex > 0 else { return }
                        let ratio = min(max((value.location.x - thumb / 2) / travel, 0), 1)
                        let target = Int((ratio * Double(lastIndex)).rounded())
                        if target != index.wrappedValue { index.wrappedValue = target }
                    }
                )
            }
            .frame(height: thumb)
            labels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(stops.indices.contains(current) ? stops[current] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index.wrappedValue = min(current + 1, lastIndex)
            case .decrement: index.wrappedValue = max(current - 1, 0)
            @unknown default: break
            }
        }
    }

    /// 档位位置占比(0...1)。
    private func fraction(_ tick: Int) -> CGFloat {
        lastIndex == 0 ? 0 : CGFloat(tick) / CGFloat(lastIndex)
    }

    @ViewBuilder private var labels: some View {
        if stops.count <= 5 {
            HStack(spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.offset) { offset, name in
                    Text(verbatim: name)
                        .font(OMFonts.caption)
                        .foregroundStyle(offset == current ? OMColors.primaryText : OMColors.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: offset == 0 ? .leading : (offset == lastIndex ? .trailing : .center))
                }
            }
        } else if let first = stops.first, let last = stops.last {
            HStack {
                Text(verbatim: first).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                Spacer(minLength: 0)
                Text(verbatim: last).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
            }
        }
    }
}

// MARK: - 主题悬浮提示

/// 符合主题风格的悬浮气泡提示 (替代系统原生黄色提示框)
public struct OMTooltipModifier: ViewModifier {
    private let text: String
    private let icon: String?
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?

    public init(text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled {
                            withAnimation(.easeOut(duration: 0.15)) { isHovered = true }
                        }
                    }
                } else {
                    withAnimation(.easeIn(duration: 0.1)) { isHovered = false }
                }
            }
            .overlay(alignment: .top) {
                if isHovered && !text.isEmpty {
                    HStack(spacing: 4) {
                        if let icon {
                            Image.om(icon, size: 10)
                                .foregroundStyle(OMColors.secondaryText)
                        }
                        Text(text)
                            .font(OMFonts.caption)
                            .foregroundStyle(OMColors.primaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(OMColors.card, in: RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous).strokeBorder(OMColors.hairline, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
                    .fixedSize()
                    .offset(y: -26)
                    .allowsHitTesting(false)
                    .zIndex(999)
                    .transition(.opacity)
                }
            }
    }
}

extension View {
    /// 附加符合主题风格的悬浮提示
    public func omTooltip(_ text: String, icon: String? = nil) -> some View {
        modifier(OMTooltipModifier(text: text, icon: icon))
            .help(text)
    }
}

