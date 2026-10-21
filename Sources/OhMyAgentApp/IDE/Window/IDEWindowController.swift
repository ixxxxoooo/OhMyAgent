// @author ixxxxoooo
// IDE 窗口控制器:一个 `IDEWindowModel` 对应一个 AppKit 窗口(不用 SwiftUI `WindowGroup`,以便精确控制生命周期与释放)。
// 窗口内容为 SwiftUI 外壳 `IDEShellView`;关闭时立即拆掉内容视图树以释放内存。

import AppKit
import IDEKit
import OMLog
import SwiftUI

@MainActor
final class IDEWindowController: NSWindowController, NSWindowDelegate {
    let model: IDEWindowModel

    /// 创建窗口(此时不显示)。
    /// - Parameters:
    ///   - model: 窗口模型
    ///   - cascadeIndex: 没有已保存外框时,用于错开新窗口位置的序号
    init(model: IDEWindowModel, cascadeIndex: Int) {
        self.model = model
        let window = NSWindow(
            contentRect: Self.initialRect(for: model, cascadeIndex: cascadeIndex),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: IDEMetrics.windowMinWidth, height: IDEMetrics.windowMinHeight)
        window.title = Self.title(for: model)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        WindowChrome.apply(to: window)
        let host = NSHostingView(rootView: IDEShellView(model: model))
        host.sceneBridgingOptions = []
        window.contentView = host
    }

    required init?(coder: NSCoder) { nil }

    /// 窗口标题(隐藏标题栏,仅供系统的 Mission Control / 辅助功能 / 窗口菜单使用)。
    /// - Parameter model: 窗口模型
    static func title(for model: IDEWindowModel) -> String {
        model.workspaceName.map { "\($0) — IDE" } ?? String(localized: "IDE — 未打开文件夹")
    }

    /// 根目录变化后刷新窗口标题。
    func refreshTitle() {
        window?.title = Self.title(for: model)
    }

    /// 初始外框:有保存的外框且仍落在某块屏幕内就沿用;否则按默认尺寸居中并按序号错开。
    private static func initialRect(for model: IDEWindowModel, cascadeIndex: Int) -> NSRect {
        if let saved = model.frame, saved.isUsable {
            let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(IDEMetrics.windowDefaultWidth, visible.width)
        let height = min(IDEMetrics.windowDefaultHeight, visible.height)
        let offset = CGFloat(cascadeIndex % 8) * 28
        return NSRect(x: visible.midX - width / 2 + offset, y: visible.midY - height / 2 - offset, width: width, height: height)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        IDEWindowManager.shared.windowDidBecomeKey(model)
    }

    func windowDidMove(_ notification: Notification) { recordFrame() }

    func windowDidResize(_ notification: Notification) { recordFrame() }

    func windowWillClose(_ notification: Notification) {
        // 先拆视图树(释放 SwiftUI 与编辑器内存),再通知管理器移除
        window?.contentView = nil
        IDEWindowManager.shared.windowWillClose(model)
    }

    private func recordFrame() {
        guard let frame = window?.frame, window?.isMiniaturized == false else { return }
        model.frame = IDEWindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
    }
}
