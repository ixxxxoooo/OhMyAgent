// @author ygw
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

import AgentHost
import AppKit
import ChatKit
import DesignSystem
import OMLog
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
        panel.prompt = "打开项目"
        panel.message = "选择 Agent 要在其中工作的项目目录"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 应用代理:激活策略与退出清理。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: ClientPrefs.Key.showDock) as? Bool ?? true
        Log.app.info("应用启动完成", ["showDock": "\(showDock)", "agentOverride": ProcessInfo.processInfo.environment["OMA_AGENT"] ?? "-", "project": ProcessInfo.processInfo.environment["OMA_PROJECT_ROOT"] ?? "-"])
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        BridgeServer.cleanStaleSockets()
        // 迁移:托盘改为默认开启,旧版本写入的「关闭」默认值不应继续生效(仅执行一次)
        if !UserDefaults.standard.bool(forKey: "migration.trayDefaultOn") {
            UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showMenuBar)
            UserDefaults.standard.set(true, forKey: "migration.trayDefaultOn")
        }
        AppNotifier.shared.install()
        AppEnvironment.shared.bootstrap()
        StatusItemController.shared.start()
        AppearanceModel.shared.applyAll()
        Task { await Toolchain.shared.setOverrides(ClientPrefs.pathOverrides()) }
        // 首帧之后再做自动更新检查,不占用启动关键路径
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            UpdateModel.shared.autoCheckIfNeeded()
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

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("应用即将退出", ["sessions": "\(AppEnvironment.shared.workbench.sessions.count)"])
        AppEnvironment.shared.workbench.shutdownAll()
        LogSystem.shared.flush()
    }
}

@main
struct OhMyAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Log.bootstrap(process: "app")
        DiagnosticsStore.shared.markLaunch()
    }

    var body: some Scene {
        Window("OhMyAgent", id: "main") {
            WorkbenchView(workbench: AppEnvironment.shared.workbench)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { WorkbenchCommands() }

        Settings { SettingsView() }
    }
}

/// 菜单命令:文件(打开项目、新对话)、视图(三栏与面板开关)、工具与扩展。
struct WorkbenchCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    private let shortcuts = ShortcutStore.shared
    private let workbench = AppEnvironment.shared.workbench

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新对话") {
                if let id = workbench.selectedProjectID { workbench.newConversation(in: id) }
            }
            .keyboardShortcut(shortcuts.shortcut(for: .newConversation))
            .disabled(workbench.activeSession?.phase != .ready)
            Button("打开项目…") {
                if let url = WorkspaceStore.chooseDirectory() { AppActions.shared.openWorkspace(url) }
            }
            .keyboardShortcut(shortcuts.shortcut(for: .openWorkspace))
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { UpdateModel.shared.checkInteractively() }
        }
        CommandGroup(replacing: .sidebar) {
            Button(workbench.layout.leftVisible ? "隐藏左栏" : "显示左栏") { workbench.toggleLeft() }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleSidebar))
            Button(workbench.layout.rightVisible ? "隐藏右栏" : "显示右栏") { workbench.toggleRight() }
                .keyboardShortcut(shortcuts.shortcut(for: .toggleInspector))
            Button(workbench.layout.bottomVisible ? "隐藏底部面板" : "显示底部面板") { workbench.toggleBottom() }
                .keyboardShortcut(shortcuts.shortcut(for: .togglePanel))
            Divider()
            Button("工具与扩展…") {
                SettingsRouter.shared.go(.tools)
                openSettings()
            }
            .keyboardShortcut(shortcuts.shortcut(for: .extensions))
        }
    }
}
