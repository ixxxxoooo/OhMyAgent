// @author ixxxxoooo
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

import AgentHost
import AppKit
import ChatKit
import DesignSystem
import LSPKit
import OMLog
import EditorKit
import SwiftUI
import WorkbenchKit

/// 工作区目录选择。
enum WorkspaceStore {
    /// 弹出目录选择面板。
    /// - Returns: 选中的目录;取消时为 nil
    @MainActor
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "打开项目")
        panel.message = String(localized: "选择 Agent 要在其中工作的项目目录")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 弹出保存面板让用户命名并创建一个新的空文件夹。
    /// - Returns: 已创建的目录;取消或创建失败时为 nil
    @MainActor
    static func createFolder() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "新建项目文件夹")
        panel.prompt = String(localized: "创建")
        panel.message = String(localized: "为新项目选择位置并命名")
        panel.nameFieldStringValue = String(localized: "新项目")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            Log.ui.error("新建项目文件夹失败", ["path": url.path, "error": "\(error)"])
            return nil
        }
    }

    /// 快速启动:在默认项目位置自动创建一个时间戳临时项目目录并直接打开。
    @MainActor
    static func createQuickStartDirectory() -> URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "QuickStart_\(formatter.string(from: Date()))"
        let dir = base.appendingPathComponent("OhMyAgent/\(name)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            Log.ui.error("创建快速启动目录失败", ["path": dir.path, "error": "\(error)"])
            return nil
        }
    }
}

/// 应用代理:激活策略与退出清理。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: ClientPrefs.Key.showDock) as? Bool ?? true
        Log.app.info("应用启动完成", ["showDock": "\(showDock)", "agentOverride": ProcessInfo.processInfo.environment["OMA_AGENT"] ?? "-", "project": ProcessInfo.processInfo.environment["OMA_PROJECT_ROOT"] ?? "-"])
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        // 旧版 socket 垫片的遗留文件清理:一次性并放到后台(临时目录条目很多时,同步枚举会让启动多卡 200ms 以上)
        if !UserDefaults.standard.bool(forKey: "migration.legacySocketsCleaned") {
            Task.detached(priority: .background) {
                BridgeServer.removeLegacySockets()
                UserDefaults.standard.set(true, forKey: "migration.legacySocketsCleaned")
            }
        }
        // 迁移:托盘改为默认开启,旧版本写入的「关闭」默认值不应继续生效(仅执行一次)
        if !UserDefaults.standard.bool(forKey: "migration.trayDefaultOn") {
            UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showMenuBar)
            UserDefaults.standard.set(true, forKey: "migration.trayDefaultOn")
        }
        LaunchTrace.mark("应用代理开始")
        if !DemoLaunch.isActive { AppNotifier.shared.install() }
        AppEnvironment.shared.bootstrap()
        LaunchTrace.mark("引导完成")
        AutomationService.shared.start()
        StatusItemController.shared.start()
        AppearanceModel.shared.applyAll()
        LaunchTrace.mark("启动完成")
        Task { await Toolchain.shared.setOverrides(ClientPrefs.pathOverrides()) }
        // 首帧之后再做自动更新检查,不占用启动关键路径
        if !DemoLaunch.isActive {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                UpdateModel.shared.autoCheckIfNeeded()
            }
        }
        // 由脚本启动(open -g)时不抢占前台焦点
        if ProcessInfo.processInfo.environment["OMA_DRAFT"] == nil && ProcessInfo.processInfo.environment["OMA_OPEN_SETTINGS"] == nil { NSApp.activate() }
    }

    /// 托盘启用时,关闭最后一个窗口后应用继续在菜单栏运行(⌘Q 或托盘菜单退出)。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !ClientPrefs.trayEnabled() }

    /// 点击 Dock 图标且没有可见窗口时重新打开窗口。
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppActions.shared.showMainWindow() }
        return true
    }

    /// 退出前若有未保存的文件,询问保存。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = FileDocumentStore.shared.dirtyDocuments
        guard !dirty.isEmpty else { return .terminateNow }
        let names = dirty.prefix(5).map { ($0.path as NSString).lastPathComponent }.joined(separator: String(localized: "、"))
        let choice = OMDialog.show(title: String(localized: "有 \(dirty.count) 个文件尚未保存"), message: names, icon: "triangle-alert", buttons: [
            .cancel(), .normal(String(localized: "不保存直接退出")), .primary(String(localized: "全部保存并退出")),
        ]).index
        switch choice {
        case 2:
            Task {
                let ok = await FileDocumentStore.shared.saveAll()
                if !ok { UpdateModel.shared.terminationCancelled() }
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case 1: return .terminateNow
        default:
            UpdateModel.shared.terminationCancelled()
            return .terminateCancel
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        UpdateModel.shared.applyOnQuitIfNeeded()
        Log.app.info("应用即将退出", ["sessions": "\(AppEnvironment.shared.workbench.conversations.count)"])
        PerfSession.logSummary()
        AppEnvironment.shared.workbench.shutdownAll()
        stopLanguageServers()
        LogSystem.shared.flush()
    }
}

/// 退出前礼貌关闭所有语言服务器(shutdown → exit),最多等待 1.5 秒,避免残留子进程。
@MainActor
private func stopLanguageServers() {
    AppEnvironment.shared.workbench.warmPool.shutdownAll()
    var finished = false
    Task {
        await LSPManager.shared.shutdownAll()
        finished = true
    }
    let deadline = Date().addingTimeInterval(1.5)
    while !finished, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

@main
struct OhMyAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // 时区以系统设置为准,不受继承来的 TZ 环境变量影响(须早于任何时间格式化与子进程启动)
        AppEnv.useSystemTimeZone()
        // 关闭系统「自动填充」启发式:它会为每个应用拉起一个常驻的「自动填充」辅助进程(占内存、无用处,
        // 本应用没有账号/密码输入场景);须早于任何文本控件创建
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicControllerEnabled": false])
        // 字体平滑偏好(AppleFontSmoothing)须早于任何文本控件创建
        FontSmoothing.applyAtLaunch()
        // 鼠标滚轮平滑(应用内,是否生效由偏好决定)
        MainActor.assumeIsolated { SmoothWheel.shared.start() }
        MainActor.assumeIsolated { ExplorerUndoCenter.shared.start() }
        Log.bootstrap(process: "app")
        PerfSession.markStart()
        LaunchTrace.mark("App 初始化")
        MainThreadHitchMonitor.shared.start()
        PerfStats.shared.startPeriodicReport()
        DemoLaunch.activateIfRequested()
        // 开发版首次启动:从稳定版复制数据与偏好(之后各自独立;演示模式使用沙盒,不复制)
        if !DemoLaunch.isActive { AppEnv.seedDevDataIfNeeded() }
        // Bundle ID 变更迁移:须早于外观、快捷键等偏好的首次读取(演示模式使用隔离沙盒,不迁移)
        if !DemoLaunch.isActive { LegacyDefaultsMigration.migrateIfNeeded() }
        // 会话存档:须在演示沙盒与开发版数据就位之后才首次取 `shared`(其根目录随主目录重定向)
        MainActor.assumeIsolated { SessionModel.archive = .shared }
        DiagnosticsStore.shared.markLaunch()
        ThemeBridges.register()
    }

    var body: some Scene {
        Window("OhMyAgent", id: "main") {
            WorkbenchView(workbench: AppEnvironment.shared.workbench)
        }
        .defaultSize(width: 1280, height: 820)
        // 不再使用 unifiedCompact 空工具栏:它的 NSTitlebarView 横跨顶部 32pt 并吞掉所有点击,
        // 导致侧栏开关/标签/设置返回按钮全部点不动;隐藏标题栏后红绿灯仍保留,顶部点击可达 SwiftUI 内容。
        .windowStyle(.hiddenTitleBar)
        .commands { WorkbenchCommands() }
    }
}

/// 菜单命令:文件(打开项目、新对话)、视图(三栏与面板开关)、工具与扩展。
struct WorkbenchCommands: Commands {
    private let shortcuts = ShortcutStore.shared
    private let workbench = AppEnvironment.shared.workbench

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新对话") { workbench.newConversationInContext() }
                .keyboardShortcut(shortcuts.shortcut(for: .newConversation))
                .disabled(workbench.activeSession.map { !$0.isAvailable } ?? false)
            Button("新会话(无需项目)") { workbench.newGeneralConversation() }
            Button("打开项目…") {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            }
            .keyboardShortcut(shortcuts.shortcut(for: .openWorkspace))
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { AppActions.shared.saveActiveFile() }
                .keyboardShortcut(shortcuts.shortcut(for: .saveFile))
            Button("全部保存") { AppActions.shared.saveAllFiles() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("关闭标签") { AppActions.shared.closeActiveTabOrWindow() }
                .keyboardShortcut(shortcuts.shortcut(for: .closeTab))
            Button("重新打开已关闭的标签") { workbench.reopenClosedTab() }
                .keyboardShortcut(shortcuts.shortcut(for: .reopenTab))
        }
        CommandMenu("标签") {
            Button("下一个标签") { workbench.cycleTab(by: 1) }
                .keyboardShortcut(shortcuts.shortcut(for: .nextTab))
            Button("上一个标签") { workbench.cycleTab(by: -1) }
                .keyboardShortcut(shortcuts.shortcut(for: .previousTab))
            Divider()
            Button("回退") { workbench.goBack() }
                .keyboardShortcut(shortcuts.shortcut(for: .goBack))
                .disabled(!workbench.nav.canGoBack)
            Button("前进") { workbench.goForward() }
                .keyboardShortcut(shortcuts.shortcut(for: .goForward))
                .disabled(!workbench.nav.canGoForward)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? String(localized: "最后一个标签") : String(localized: "第 \(number) 个标签")) { workbench.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("在编辑器中查找…") { CodeEditorView.showFindInActiveEditor() }
                .keyboardShortcut("f", modifiers: .command)
            Button("替换…") { CodeEditorView.showFindInActiveEditor(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("查找下一个") { CodeEditorView.findInActiveEditor(forward: true) }
                .keyboardShortcut("g", modifiers: .command)
            Button("查找上一个") { CodeEditorView.findInActiveEditor(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("搜索…") { HubModel.shared.present(.all, workbench: workbench) }
                .keyboardShortcut(shortcuts.shortcut(for: .hubSearch))
            Button("快速打开文件…") { PaletteModel.present(.files, workbench: workbench) }
                .keyboardShortcut(shortcuts.shortcut(for: .quickOpen))
            Button("命令面板…") { PaletteModel.present(.commands, workbench: workbench) }
                .keyboardShortcut(shortcuts.shortcut(for: .commandPalette))
            Button("在文件中搜索") { workbench.showRight(.search); SearchModel.shared.requestFocus() }
                .keyboardShortcut(shortcuts.shortcut(for: .globalSearch))
            Button("新建终端") { AppActions.shared.newTerminal() }
                .keyboardShortcut(shortcuts.shortcut(for: .newTerminal))
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { AppActions.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("切换颜色主题…") { HubModel.shared.presentThemes(workbench: workbench) }
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { UpdateModel.shared.checkInteractively() }
        }
        CommandGroup(replacing: .sidebar) {
            Button(WorkbenchPanelNames.toggleTitle(.sidebar, visible: workbench.layout.leftVisible)) { workbench.toggleLeft() }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleSidebar))
            Button(WorkbenchPanelNames.toggleTitle(.tools, visible: workbench.layout.rightVisible)) { workbench.toggleRight() }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleInspector))
            Button(workbench.isTerminalShown ? String(localized: "隐藏终端") : String(localized: "显示终端")) { workbench.toggleTerminal() }
                .keyboardShortcut(shortcuts.shortcut(for: .togglePanel))
            Button(workbench.isOutputShown ? String(localized: "隐藏输出面板") : String(localized: "显示输出面板")) { workbench.toggleOutput() }
            Divider()
            Button("工具与扩展…") {
                AppActions.shared.openSettings(page: .mcp)
            }
            .keyboardShortcut(shortcuts.shortcut(for: .extensions))
        }
    }
}
