// @author ygw
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

import AgentHost
import AppKit
import ChatKit
import DesignSystem
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

    func register(_ model: SessionModel) { storage[ObjectIdentifier(model)] = model }
    func unregister(_ model: SessionModel) { storage[ObjectIdentifier(model)] = nil }
    func shutdownAll() { for model in storage.values { model.shutdown() } }
}

/// 应用代理:激活策略与退出清理。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: ClientPrefs.Key.showDock) as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        BridgeServer.cleanStaleSockets()
        AppearanceModel.shared.applyAll()
        Task { await Toolchain.shared.setOverrides(ClientPrefs.pathOverrides()) }
        // 由脚本启动(open -g)时不抢占前台焦点
        if ProcessInfo.processInfo.environment["OMA_DRAFT"] == nil && ProcessInfo.processInfo.environment["OMA_OPEN_EXTENSIONS"] == nil && ProcessInfo.processInfo.environment["OMA_OPEN_SETTINGS"] == nil { NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        SessionRegistry.shared.shutdownAll()
    }
}

@main
struct OhMyAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(ClientPrefs.Key.showMenuBar) private var showMenuBar = false
    @AppStorage(ClientPrefs.Key.showDock) private var showDock = true

    init() { DiagnosticsStore.shared.markLaunch() }

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

        MenuBarExtra("OhMyAgent", systemImage: "sparkles", isInserted: .constant(showMenuBar || !showDock)) {
            MenuBarContent()
        }
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
        CommandGroup(after: .toolbar) {
            Button("扩展管理…") { openWindow(id: "extensions", value: WorkspaceStore.defaultWorkspace) }
                .keyboardShortcut(shortcuts.shortcut(for: .extensions))
        }
    }
}

/// 菜单栏图标菜单。
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开工作区…") {
            NSApp.activate()
            if let url = WorkspaceStore.chooseDirectory() { openWindow(value: url) }
        }
        Button("扩展管理…") {
            NSApp.activate()
            openWindow(id: "extensions", value: WorkspaceStore.defaultWorkspace)
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 OhMyAgent") { NSApp.terminate(nil) }
    }
}
