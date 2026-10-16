// @author ixxxxoooo
// 菜单栏托盘:NSStatusItem + NSMenu。
// 图标右下角的状态点:运行中闪烁(蓝)、待处理闪烁(橙)、未读完成常亮(绿);已读后消失。
// 不使用 SwiftUI MenuBarExtra(它在状态变化时的刷新循环曾造成 CPU 空转),菜单仅在打开时构建。

import IconKit
import AppKit
import ChatKit
import DesignSystem
import OMLog

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var isSyncing = false
    private let attention = AttentionCenter.shared

    /// 启动:接入注意力变化、偏好变化,并按偏好显示托盘。
    func start() {
        attention.onChange = { [weak self] in self?.refresh() }
        attention.onFinished = { item in AppNotifier.sendFinished(item) }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVisibility() }
        }
        // 主题切换:托盘状态点颜色随主题重绘
        NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        syncVisibility()
    }

    /// 根据偏好创建或移除状态项。
    func syncVisibility() {
        // 创建状态项本身会写 UserDefaults 并同步触发 didChange 通知,必须防止重入
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let enabled = ClientPrefs.trayEnabled()
        if enabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // 先赋值再设置 autosaveName:后者会写 UserDefaults 并同步触发 didChange 通知,避免重入创建
            statusItem = item
            item.autosaveName = "OhMyAgentStatusItem"
            item.menu = makeMenu()
            item.button?.setAccessibilityLabel("OhMyAgent")
            Log.app.info("托盘已显示")
            refresh()
        } else if !enabled, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            stopBlink()
            Log.app.info("托盘已隐藏")
        }
    }

    // MARK: 图标与闪烁

    /// 刷新图标与闪烁定时器。
    func refresh() {
        guard let button = statusItem?.button else { return }
        let indicator = attention.indicator
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let blinks = (indicator == .running || indicator == .needsInput) && !reduceMotion
        if blinks { startBlink() } else { stopBlink() }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = Self.icon(indicator: indicator, dotVisible: blinks ? blinkVisible : true, dark: dark)
        button.toolTip = Self.tooltip(attention)
        NSApp.dockTile.badgeLabel = {
            let n = attention.count(of: .unreadDone) + attention.count(of: .needsInput)
            return n > 0 ? "\(n)" : nil
        }()
    }

    private func startBlink() {
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.blinkVisible.toggle()
                self.refresh()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkVisible = true
    }

    private static func tooltip(_ attention: AttentionCenter) -> String {
        var parts: [String] = []
        let running = attention.count(of: .running), input = attention.count(of: .needsInput), unread = attention.count(of: .unreadDone)
        if running > 0 { parts.append(String(localized: "\(running) 个会话运行中")) }
        if input > 0 { parts.append(String(localized: "\(input) 个会话等待处理")) }
        if unread > 0 { parts.append(String(localized: "\(unread) 个未读完成")) }
        return parts.isEmpty ? "OhMyAgent" : "OhMyAgent · " + parts.joined(separator: " · ")
    }

    /// 状态点颜色。
    static func dotColor(_ indicator: TrayIndicator) -> NSColor? {
        switch indicator {
        case .none: return nil
        case .running: return NSColor(OMColors.statusRunning)
        case .needsInput: return NSColor(OMColors.statusWaiting)
        case .unread: return NSColor(OMColors.statusUnread)
        }
    }

    /// 绘制菜单栏图标:四角星(按菜单栏明暗取白/黑)+ 右下角状态点。
    /// 不依赖绘制闭包里的动态颜色解析(状态栏按钮中不稳定),而是显式传入明暗。
    static func icon(indicator: TrayIndicator, dotVisible: Bool, dark: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let ink: NSColor = dark ? NSColor(OMColors.onAccent) : NSColor(OMColors.maskInk).withAlphaComponent(0.9) // ui-lint:allow 菜单栏前景由系统菜单栏明暗决定
        let image = NSImage(size: size, flipped: false) { rect in
            ink.setFill()
            starPath(center: NSPoint(x: 8.2, y: 9.8), radius: 7.2).fill()
            starPath(center: NSPoint(x: 13.6, y: 14.2), radius: 3.0).fill()
            if let color = dotColor(indicator), dotVisible {
                let dotRect = NSRect(x: rect.maxX - 5.8, y: 0.6, width: 4.8, height: 4.8)
                // 点外围留一圈细描边,在深浅菜单栏上都清晰
                (dark ? NSColor(OMColors.maskInk).withAlphaComponent(0.55) : NSColor(OMColors.onAccent).withAlphaComponent(0.7)).setFill()
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.6, dy: -0.6)).fill()
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func starPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let waist = radius * 0.16
        path.move(to: NSPoint(x: center.x, y: center.y + radius))
        path.curve(to: NSPoint(x: center.x + radius, y: center.y), controlPoint1: NSPoint(x: center.x + waist, y: center.y + waist), controlPoint2: NSPoint(x: center.x + waist, y: center.y + waist))
        path.curve(to: NSPoint(x: center.x, y: center.y - radius), controlPoint1: NSPoint(x: center.x + waist, y: center.y - waist), controlPoint2: NSPoint(x: center.x + waist, y: center.y - waist))
        path.curve(to: NSPoint(x: center.x - radius, y: center.y), controlPoint1: NSPoint(x: center.x - waist, y: center.y - waist), controlPoint2: NSPoint(x: center.x - waist, y: center.y - waist))
        path.curve(to: NSPoint(x: center.x, y: center.y + radius), controlPoint1: NSPoint(x: center.x - waist, y: center.y + waist), controlPoint2: NSPoint(x: center.x - waist, y: center.y + waist))
        path.close()
        return path
    }

    // MARK: 菜单

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "OhMyAgent")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let started = ContinuousClock.now
        // 状态摘要
        let running = attention.count(of: .running), input = attention.count(of: .needsInput), unread = attention.count(of: .unreadDone)
        if running + input + unread > 0 {
            let header = NSMenuItem(title: Self.tooltip(attention).replacingOccurrences(of: "OhMyAgent · ", with: ""), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if unread > 0 { menu.addItem(item(String(localized: "全部标为已读")) { [attention] in attention.markAllRead() }) }
            menu.addItem(.separator())
        }
        menu.addItem(item(String(localized: "打开 OhMyAgent")) { AppActions.shared.showMainWindow() })
        menu.addItem(item(String(localized: "新对话"), key: "n") { AppActions.shared.newConversation() })
        menu.addItem(item(String(localized: "打开项目…"), key: "o") {
            NSApp.activate()
            if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
        })

        // 最近项目
        let projects = RecentStore.projects()
        let projectMenu = NSMenu()
        for path in projects.prefix(10) {
            let entry = item((path as NSString).lastPathComponent) { AppActions.shared.openWorkspace(URL(fileURLWithPath: path)) }
            entry.toolTip = (path as NSString).abbreviatingWithTildeInPath
            entry.image = OMIconRenderer.nsImage("folder", size: 14)
            projectMenu.addItem(entry)
        }
        if !projects.isEmpty {
            projectMenu.addItem(.separator())
            projectMenu.addItem(item(String(localized: "清除最近项目")) { RecentStore.clearProjects() })
        }
        let projectsItem = NSMenuItem(title: String(localized: "最近项目"), action: nil, keyEquivalent: "")
        projectsItem.submenu = projectMenu
        projectsItem.isEnabled = !projects.isEmpty
        menu.addItem(projectsItem)

        // 最近会话:进行中的在前,附状态点
        menu.addItem(.separator())
        let sessionsHeader = NSMenuItem(title: String(localized: "最近会话"), action: nil, keyEquivalent: "")
        sessionsHeader.isEnabled = false
        menu.addItem(sessionsHeader)
        var shown = Set<String>()
        var count = 0
        for live in attention.sortedItems where count < 8 {
            let entry = item(Self.sessionTitle(live.title, project: live.project)) {
                AppActions.shared.openSession(workspacePath: live.workspacePath, sessionId: live.sessionId, title: live.title, uid: live.id)
            }
            entry.toolTip = "\(live.title) — \(live.project)"
            entry.image = Self.dotImage(Self.dotColor(Self.indicator(of: live.state)))
            menu.addItem(entry)
            if let sid = live.sessionId { shown.insert(sid) }
            count += 1
        }
        for recent in RecentStore.sessions() where count < 8 && !shown.contains(recent.sessionId) {
            let project = (recent.workspacePath as NSString).lastPathComponent
            let entry = item(Self.sessionTitle(recent.title, project: project)) {
                AppActions.shared.openSession(workspacePath: recent.workspacePath, sessionId: recent.sessionId, title: recent.title)
            }
            entry.toolTip = "\(recent.title) — \(project)"
            entry.image = Self.dotImage(nil)
            menu.addItem(entry)
            count += 1
        }
        if count == 0 {
            let empty = NSMenuItem(title: String(localized: "暂无会话"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "设置…"), key: ",") { AppActions.shared.openSettings() })
        menu.addItem(item(String(localized: "检查更新…")) { UpdateModel.shared.checkInteractively() })
        menu.addItem(item(String(localized: "重新启动 OhMyAgent"), key: "r") { AppActions.shared.relaunch() })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "退出 OhMyAgent"), key: "q") { NSApp.terminate(nil) })
        Log.perf.debug("托盘菜单构建", ["ms": "\(Int(started.duration(to: .now) / .milliseconds(1)))", "sessions": "\(count)"])
    }

    private static func indicator(of state: AttentionState) -> TrayIndicator {
        switch state {
        case .idle: return .none
        case .unreadDone: return .unread
        case .running: return .running
        case .needsInput: return .needsInput
        }
    }

    private static func sessionTitle(_ title: String, project: String) -> String {
        let maxLen = 18
        let clipped = title.count > maxLen ? String(title.prefix(maxLen)) + "…" : title
        return "\(clipped) — \(project)"
    }

    /// 菜单项前的状态点(无状态时为透明占位,保持对齐)。
    private static func dotImage(_ color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func item(_ title: String, key: String = "", action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: String(localized: String.LocalizationValue(title)), keyEquivalent: key, handler: action)
        entry.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        return entry
    }
}

/// 带闭包的菜单项。
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) 不可用") }

    @objc private func fire() { handler() }
}
