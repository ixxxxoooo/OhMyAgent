// @author ygw
// 应用入口:每个 Workspace 一个窗口,每个窗口独占一个 Agent 子进程。

import AgentHost
import AppKit
import ChatKit
import DesignSystem
import LSPKit
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

    /// 退出前若有未保存的文件,询问保存。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = FileDocumentStore.shared.dirtyDocuments
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "有 \(dirty.count) 个文件尚未保存")
        alert.informativeText = dirty.prefix(5).map { ($0.path as NSString).lastPathComponent }.joined(separator: "、")
        alert.addButton(withTitle: String(localized: "全部保存并退出"))
        alert.addButton(withTitle: String(localized: "不保存直接退出"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let ok = await FileDocumentStore.shared.saveAll()
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("应用即将退出", ["sessions": "\(AppEnvironment.shared.workbench.sessions.count)"])
        AppEnvironment.shared.workbench.shutdownAll()
        stopLanguageServers()
        LogSystem.shared.flush()
    }
}

/// 退出前礼貌关闭所有语言服务器(shutdown → exit),最多等待 1.5 秒,避免残留子进程。
@MainActor
private func stopLanguageServers() {
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
        Log.bootstrap(process: "app")
        DiagnosticsStore.shared.markLaunch()
    }

    var body: some Scene {
        Window("OhMyAgent", id: "main") {
            WorkbenchView(workbench: AppEnvironment.shared.workbench)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { WorkbenchCommands() }
    }
}

/// 菜单命令:文件(打开项目、新对话)、视图(三栏与面板开关)、工具与扩展。
struct WorkbenchCommands: Commands {
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
        CommandGroup(replacing: .saveItem) {
            Button("保存") { AppActions.shared.saveActiveFile() }
                .keyboardShortcut(shortcuts.shortcut(for: .saveFile))
            Button("全部保存") { AppActions.shared.saveAllFiles() }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("快速打开文件…") { PaletteModel.shared.present(.files, workbench: workbench) }
                .keyboardShortcut(shortcuts.shortcut(for: .quickOpen))
            Button("命令面板…") { PaletteModel.shared.present(.commands, workbench: workbench) }
                .keyboardShortcut(shortcuts.shortcut(for: .commandPalette))
            Button("在文件中搜索") { workbench.showRight(.search); SearchModel.shared.requestFocus() }
                .keyboardShortcut(shortcuts.shortcut(for: .globalSearch))
            Button("新建终端标签") { AppActions.shared.openTerminal() }
                .keyboardShortcut(shortcuts.shortcut(for: .newTerminal))
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { AppActions.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
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
                AppActions.shared.openSettings(page: .tools)
            }
            .keyboardShortcut(shortcuts.shortcut(for: .extensions))
        }
    }
}
