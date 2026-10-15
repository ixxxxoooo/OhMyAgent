// @author ygw
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

import AgentHost
import AppKit
import ChatKit
import DesignSystem
import OMLog
import SwiftUI

/// 工作区记录(最近使用)。
enum WorkspaceStore {
    private static let lastKey = "lastWorkspacePath"

    /// 默认工作区:最近使用的目录,否则为用户主目录。
    static var defaultWorkspace: URL {
        if let path = UserDefaults.standard.string(forKey: lastKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// 记录最近使用的工作区。
    /// - Parameter url: 目录
    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastKey)
        RecentStore.recordProject(url.path)
    }

    /// 弹出目录选择面板。
    /// - Returns: 选中的目录;取消时为 nil
    @MainActor
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开工作区"
        panel.message = "选择 Agent 要在其中工作的项目目录"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 会话注册表:应用退出时统一回收所有 Agent 子进程。
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()
    private var storage: [ObjectIdentifier: SessionModel] = [:]

    /// 当前所有会话(设置页读取用量与鉴权信息)。
    var models: [SessionModel] { Array(storage.values) }

    func register(_ model: SessionModel) {
        storage[ObjectIdentifier(model)] = model
        Log.session.info("会话已注册", ["workspace": model.workspace.path, "total": "\(storage.count)"])
    }
    func unregister(_ model: SessionModel) {
        storage[ObjectIdentifier(model)] = nil
        Log.session.info("会话已注销", ["workspace": model.workspace.path, "total": "\(storage.count)"])
    }
    func shutdownAll() { for model in storage.values { model.shutdown() } }
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
        StatusItemController.shared.start()
        AppearanceModel.shared.applyAll()
        Task { await Toolchain.shared.setOverrides(ClientPrefs.pathOverrides()) }
        // 首帧之后再做自动更新检查,不占用启动关键路径
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            UpdateModel.shared.autoCheckIfNeeded()
        }
        // 由脚本启动(open -g)时不抢占前台焦点
        if ProcessInfo.processInfo.environment["OMA_DRAFT"] == nil && ProcessInfo.processInfo.environment["OMA_OPEN_EXTENSIONS"] == nil && ProcessInfo.processInfo.environment["OMA_OPEN_SETTINGS"] == nil { NSApp.activate() }
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
        Log.app.info("应用即将退出", ["sessions": "\(SessionRegistry.shared.models.count)"])
        SessionRegistry.shared.shutdownAll()
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
        WindowGroup("OhMyAgent", for: URL.self) { $workspace in
            WorkspaceWindow(workspace: workspace)
        } defaultValue: {
            WorkspaceStore.defaultWorkspace
        }
        .defaultSize(width: 1120, height: 780)
        .commands { WorkspaceCommands() }

        WindowGroup("扩展管理", id: "extensions", for: URL.self) { $workspace in
            ExtensionsWindow(workspace: workspace ?? WorkspaceStore.defaultWorkspace)
        }
        .defaultSize(width: 1040, height: 700)

        Settings { SettingsView() }

    }
}

/// 菜单命令:打开工作区。
struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private let shortcuts = ShortcutStore.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开工作区…") {
                if let url = WorkspaceStore.chooseDirectory() { openWindow(value: url) }
            }
            .keyboardShortcut(shortcuts.shortcut(for: .openWorkspace))
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { UpdateModel.shared.checkInteractively() }
        }
        CommandGroup(after: .toolbar) {
            Button("扩展管理…") { openWindow(id: "extensions", value: WorkspaceStore.defaultWorkspace) }
                .keyboardShortcut(shortcuts.shortcut(for: .extensions))
        }
    }
}

