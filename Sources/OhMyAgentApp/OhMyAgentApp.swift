// @author ygw
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

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
    private var models: [ObjectIdentifier: SessionModel] = [:]

    func register(_ model: SessionModel) { models[ObjectIdentifier(model)] = model }
    func unregister(_ model: SessionModel) { models[ObjectIdentifier(model)] = nil }
    func shutdownAll() { for model in models.values { model.shutdown() } }
}

/// 应用代理:激活策略与退出清理。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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

    var body: some Scene {
        WindowGroup("OhMyAgent", for: URL.self) { $workspace in
            WorkspaceWindow(workspace: workspace)
        } defaultValue: {
            WorkspaceStore.defaultWorkspace
        }
        .defaultSize(width: 1120, height: 780)
        .commands { WorkspaceCommands() }
    }
}

/// 菜单命令:打开工作区。
struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开工作区…") {
                if let url = WorkspaceStore.chooseDirectory() { openWindow(value: url) }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
