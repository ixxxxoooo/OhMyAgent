// @author ixxxxoooo
// 全局唯一的悬浮提示:整个应用只有这一套(`omTooltip`),禁止再用系统 `.help`(系统提示不跟主题、样式与应用不一致)。
// 提示显示在独立的无边框面板里,不会被任何父视图裁切或遮挡;样式随主题:
// 纸感(`allowsGlass == false`)= 不透明卡片 + 发丝线、无阴影;玻璃主题 = Liquid Glass + 系统阴影。

import AppKit
import IconKit
import SwiftUI

/// 悬浮提示中心(单例):同一时刻最多显示一个提示。
@MainActor
public final class OMTooltipCenter {
    public static let shared = OMTooltipCenter()

    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?
    private var owner: UUID?
    private var isVisible = false
    private var monitor: Any?
    private var resignObserver: Any?

    private init() {}

    /// 悬停开始:稍等片刻后在光标附近显示提示;已有提示显示时(在相邻控件间移动)几乎立即切换。
    /// - Parameters:
    ///   - owner: 发起悬停的视图标识(用于只关闭自己的提示)
    ///   - text: 提示文字(空串不显示)
    ///   - icon: 可选 Lucide 图标
    public func schedule(owner: UUID, text: String, icon: String?) {
        guard !text.isEmpty else { return }
        showTask?.cancel()
        self.owner = owner
        let delay: Duration = isVisible ? .milliseconds(40) : .milliseconds(450)
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.owner == owner else { return }
            self.present(text: text, icon: icon)
        }
    }

    /// 悬停结束或视图消失:关闭该视图发起的提示。
    /// - Parameter owner: 视图标识;传 nil 无条件关闭
    public func hide(owner: UUID?) {
        if let owner, owner != self.owner { return }
        showTask?.cancel()
        self.owner = nil
        guard isVisible else { return }
        isVisible = false
        panel?.orderOut(nil)
    }

    /// 提示文字在悬停期间变化(如「复制」→「已复制」)时就地刷新。
    func refresh(owner: UUID, text: String, icon: String?) {
        guard isVisible, self.owner == owner else { return }
        present(text: text, icon: icon)
    }

    private func present(text: String, icon: String?) {
        let host = NSHostingView(rootView: OMTooltipBubble(text: text, icon: icon))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认在光标右下方;放不下就翻到左侧/上方
        var x = mouse.x + 12
        var y = mouse.y - size.height - 16
        if x + size.width > area.maxX - 4 { x = mouse.x - size.width - 8 }
        if y < area.minY + 4 { y = mouse.y + 20 }
        x = max(area.minX + 4, x)
        y = min(max(area.minY + 4, y), area.maxY - size.height - 4)

        let panel = self.panel ?? makePanel()
        panel.contentView = host
        panel.hasShadow = ThemeRuntime.style.allowsGlass
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        isVisible = true
        installDismissHooks()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }

    /// 点击、滚动、按键、应用失去焦点时关闭提示。
    private func installDismissHooks() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { event in
                MainActor.assumeIsolated { OMTooltipCenter.shared.hide(owner: nil) }
                return event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { OMTooltipCenter.shared.hide(owner: nil) }
            }
        }
    }
}

/// 提示气泡:随主题取色;纸感不透明 + 发丝线,玻璃主题用 Liquid Glass。
struct OMTooltipBubble: View {
    let text: String
    let icon: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OMRadius.tag, style: .continuous)
        let content = HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let icon {
                Image.om(icon, size: 11).foregroundStyle(OMColors.secondaryText)
            }
            Text(verbatim: text)
                .font(OMFonts.caption)
                .foregroundStyle(OMColors.primaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        if ThemeRuntime.style.allowsGlass {
            content
                .omGlass(in: shape)
                .overlay(shape.strokeBorder(OMColors.hairline.opacity(0.5), lineWidth: 0.5))
        } else {
            content
                .background(OMColors.card, in: shape)
                .overlay(shape.strokeBorder(OMColors.hairline, lineWidth: 0.5))
        }
    }
}

/// 悬浮提示修饰器:只负责上报悬停,真正的显示由 `OMTooltipCenter` 完成。
/// 本地化查表推迟到真正悬停(或文字变化)时:界面上带提示的控件成百上千,
/// 若在每次 `body` 里都查 `Bundle`,滚动/重算时白白付出这笔开销。
public struct OMTooltipModifier: ViewModifier {
    /// 未本地化的原文(中文键或已本地化的字符串)
    private let rawText: String
    private let icon: String?
    @State private var id = UUID()

    /// - Parameters:
    ///   - text: 提示原文(悬停时才按当前语言查表)
    ///   - icon: 可选 Lucide 图标
    public init(text: String, icon: String? = nil) {
        self.rawText = text
        self.icon = icon
    }

    /// 按当前语言查表后的提示文字。
    private var localized: String { Bundle.main.localizedString(forKey: rawText, value: nil, table: nil) }

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering { OMTooltipCenter.shared.schedule(owner: id, text: localized, icon: icon) }
                else { OMTooltipCenter.shared.hide(owner: id) }
            }
            .onChange(of: rawText) { OMTooltipCenter.shared.refresh(owner: id, text: localized, icon: icon) }
            .onDisappear { OMTooltipCenter.shared.hide(owner: id) }
            // Text 在渲染时才解析本地化,body 里不查表;字符串按键处理、不做格式化
            .accessibilityHint(Text(LocalizedStringResource(String.LocalizationValue(rawText))))
    }
}

extension View {
    /// 悬浮提示(全应用唯一入口,替代系统 `.help`)。字面量与已本地化的字符串都会按当前语言查表。
    /// - Parameters:
    ///   - text: 提示文字
    ///   - icon: 可选 Lucide 图标
    public func omTooltip<S: StringProtocol>(_ text: S, icon: String? = nil) -> some View {
        modifier(OMTooltipModifier(text: String(text), icon: icon))
    }
}

extension View {
    /// 悬浮提示(本地化键写法):给以 `LocalizedStringKey` 传参的辅助方法用。
    /// - Parameters:
    ///   - key: 本地化键(中文原文)
    ///   - icon: 可选 Lucide 图标
    public func omTooltip(_ key: LocalizedStringKey, icon: String? = nil) -> some View {
        // LocalizedStringKey 不公开原文,经反射取回键再按当前语言查表
        let raw = Mirror(reflecting: key).children.first { $0.label == "key" }?.value as? String ?? ""
        return omTooltip(raw, icon: icon)
    }
}
