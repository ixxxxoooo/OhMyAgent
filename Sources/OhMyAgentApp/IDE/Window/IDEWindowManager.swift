// @author ixxxxoooo
// IDE 窗口管理器:进程内唯一,持有注册表与各窗口控制器,负责打开/聚焦/关闭、启动恢复,
// 以及 Agent 窗口 ↔ IDE 窗口的一键切换(⌃⌘I)。窗口数据在 IDEKit(`IDEWindowRegistry`),这里只做 AppKit 侧的编排。

import AppKit
import ChatKit
import EditorKit
import IDEKit
import OMLog
import WorkbenchKit

@MainActor
final class IDEWindowManager {
    static let shared = IDEWindowManager()

    /// 窗口注册表(模型与持久化)
    let registry: IDEWindowRegistry
    /// 已创建的窗口控制器(按窗口标识)
    private var controllers: [UUID: IDEWindowController] = [:]
    /// 应用正在退出:此时窗口随进程消失,不应从注册表移除(下次启动要恢复)
    private(set) var isTerminating = false
    /// 已创建过的窗口总数(用于错开新窗口位置)
    private var createdCount = 0

    private init() {
        registry = IDEWindowRegistry()
        // 编辑器里按 ⌃G:IDE 窗口弹出「转到行」输入
        OMEditorView.goToLineHandler = { [weak self] in self?.route(.goToLine) }
    }

    // MARK: 查询

    /// 当前已显示(有控制器)的 IDE 窗口数。
    var openCount: Int { controllers.count }

    /// 某个 `NSWindow` 对应的 IDE 窗口模型(不是 IDE 窗口时为 nil)。
    /// - Parameter window: AppKit 窗口
    func model(for window: NSWindow) -> IDEWindowModel? {
        controllers.values.first { $0.window === window }?.model
    }

    /// 某个模型的窗口控制器。
    /// - Parameter model: 窗口模型
    func controller(for model: IDEWindowModel) -> IDEWindowController? { controllers[model.id] }

    /// 当前键盘窗口若是 IDE 窗口,返回它的工作区(「在哪个窗口操作就在哪个窗口显示」的路由依据)。
    var keyWorkspace: IDEWorkspace? {
        WindowContext.shared.ideModel.flatMap { controllers[$0.id]?.workspace }
    }

    // MARK: 打开与切换

    /// 打开(或聚焦)某根目录的 IDE 窗口。
    /// - Parameters:
    ///   - root: 工作区根目录;nil 为空窗口
    ///   - forceNew: 强制新开
    /// - Returns: 窗口模型
    ///   - adoptFrame: 融合模式下沿用的来源窗口外框
    @discardableResult
    func open(root: String?, forceNew: Bool = false, adoptFrame: NSRect? = nil, replacing source: NSWindow? = nil) -> IDEWindowModel {
        let (model, _) = registry.open(root: root, forceNew: forceNew)
        show(model, reason: "open", adoptFrame: adoptFrame, replacing: source)
        return model
    }

    /// Agent → IDE:聚焦当前项目的 IDE 窗口,没有就新建。
    /// 融合模式下:IDE 窗口沿用 Agent 窗口的外框,并隐藏 Agent 窗口(原地换模式);会话与项目本就共用。
    /// - Parameter forceNew: ⌥ 点击强制新开
    func switchToIDE(forceNew: Bool = false) {
        let root = AppEnvironment.shared.workbench.selectedProject?.id
        let source = Self.fusionSource(AppActions.shared.mainWindow)
        // IDE 窗口一定会被创建并显示:它叠在来源窗口正上方淡入,淡入完成后来源窗口才隐藏(无闪烁、无跳动)
        open(root: root, forceNew: forceNew, adoptFrame: source?.frame, replacing: source)
        if FusionMode.shared.isEnabled { UserDefaults.standard.set(true, forKey: Self.fusionLastIDEKey) }
    }

    /// IDE → Agent:前置 Agent 窗口,并选中该 IDE 窗口对应的项目(项目不在工作台时加入)。
    func switchToAgent() {
        let span = Log.perf.span("IDE 切换到 Agent", warnMs: 50, quiet: true)
        let workbench = AppEnvironment.shared.workbench
        // 融合模式:离开前保存未保存的文件(Agent 读磁盘,两边内容才一致),并记下 IDE 窗口以便沿用外框、随后隐藏
        var source: NSWindow?
        if case .ide(let id) = WindowContext.shared.kind, FusionMode.shared.isEnabled, let controller = controllers[id] {
            source = Self.fusionSource(controller.window)
            if source != nil { controller.workspace.saveAll() }
        }
        if case .ide(let id) = WindowContext.shared.kind, let root = registry.window(id: id)?.workspaceRoot {
            if workbench.projects.contains(where: { $0.id == root }) {
                if workbench.selectedProjectID != root { workbench.select(project: root) }
            } else {
                workbench.openProject(URL(fileURLWithPath: root))
            }
        }
        // 只有 Agent 窗口确实显示出来才隐藏 IDE 窗口,避免两个窗口都不可见
        let shown = AppActions.shared.showMainWindow(adopting: source?.frame, replacing: source)
        if shown {
            if FusionMode.shared.isEnabled { UserDefaults.standard.set(false, forKey: Self.fusionLastIDEKey) }
        }
        span.end()
    }

    /// 融合模式下可作为「来源」的窗口:模式开启、窗口存在且不在全屏(全屏窗口不能原地隐藏换位)。
    /// - Parameter window: 来源窗口
    /// - Returns: 可用的来源窗口;否则 nil(走普通的两窗口切换)
    private static func fusionSource(_ window: NSWindow?) -> NSWindow? {
        guard FusionMode.shared.isEnabled, let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return nil }
        return window
    }

    /// ⌃⌘I:在 Agent 窗口与 IDE 窗口之间切换。
    func toggleMode() {
        if WindowContext.shared.isIDE { switchToAgent() } else { switchToIDE() }
    }

    /// ⇧⌘N:新建一个空的 IDE 窗口。
    func newEmptyWindow() {
        open(root: nil, forceNew: true)
    }

    /// 选择文件夹并在 IDE 窗口中打开(已有同根窗口则聚焦它)。
    func openFolderInNewWindow() {
        guard let url = WorkspaceStore.chooseDirectory() else { return }
        open(root: url.path)
    }

    /// 给空窗口选择文件夹。
    /// - Parameter model: 目标窗口模型
    func chooseFolder(for model: IDEWindowModel) {
        guard let url = WorkspaceStore.chooseDirectory(), let root = IDEMetrics.normalizedRoot(url.path) else { return }
        // 已有别的窗口打开了该目录:聚焦它,当前空窗口保持不变
        if let existing = registry.window(forRoot: root), existing !== model {
            show(existing, reason: "reuse")
            return
        }
        model.workspaceRoot = root
        controllers[model.id]?.refreshTitle()
    }

    /// 启动时恢复上次打开的 IDE 窗口(最近使用的最后显示,落在最前)。
    /// 融合模式:上次退出时停在 Agent 模式就不恢复 IDE 窗口(它们已被隐藏);停在编辑器模式则恢复并隐藏 Agent 窗口(两个窗口不叠在一起)。
    func restoreWindows() {
        let models = registry.windows
        guard !models.isEmpty else { return }
        let fusion = FusionMode.shared.isEnabled
        if fusion, !UserDefaults.standard.bool(forKey: Self.fusionLastIDEKey) {
            Log.app.info("融合模式:上次停在 Agent 模式,不恢复 IDE 窗口", ["count": "\(models.count)"])
            return
        }
        Log.app.info("恢复 IDE 窗口", ["count": "\(models.count)", "fusion": "\(fusion)"])
        for model in models.reversed() { show(model, reason: "restore", activate: model === models.first) }
        if fusion { Task { await hideMainWindowWhenReady() } }
    }

    /// 记住当前所处模式,供下次启动恢复(仅融合模式)。
    /// - Parameter isIDE: 当前是否在 IDE(编辑器)模式
    func rememberLaunchMode(isIDE: Bool) {
        guard FusionMode.shared.isEnabled else { return }
        UserDefaults.standard.set(isIDE, forKey: Self.fusionLastIDEKey)
    }

    /// 启动时是否会恢复到编辑器模式(融合模式、上次停在编辑器、且有可恢复的 IDE 窗口)。
    private var startsInEditorMode: Bool {
        FusionMode.shared.isEnabled && UserDefaults.standard.bool(forKey: Self.fusionLastIDEKey) && !registry.windows.isEmpty
    }

    /// 启动时只执行一次的标记:Agent 窗口首次登记时是否已按「编辑器模式」处理过
    private var launchHideHandled = false

    /// Agent 窗口一创建就隐藏(启动将恢复到编辑器模式时),避免它先闪现、等 IDE 窗口就绪后才被 `hideMainWindowWhenReady` 隐藏。
    /// - Parameter window: 刚登记的 Agent 窗口
    func hideMainWindowIfLaunchingIntoEditor(_ window: NSWindow) {
        guard !launchHideHandled else { return }
        launchHideHandled = true
        guard startsInEditorMode else { return }
        window.orderOut(nil)
    }

    /// 融合模式启动恢复到编辑器模式后,等 Agent 窗口登记完成再把它隐藏(最多等 6 秒)。
    private func hideMainWindowWhenReady() async {
        for _ in 0..<60 {
            if let window = AppActions.shared.mainWindow {
                window.orderOut(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 融合模式下最近一次停留的模式(true 为编辑器),退出后下次启动据此恢复。
    private static let fusionLastIDEKey = "general.fusionLastIDE"

    // MARK: 命令路由

    /// 在 IDE 窗口里可被菜单/快捷键派发的命令。
    enum Command {
        case toggleSidebar, togglePanel, toggleAgentPane, maximizeAgentPane, perfHUD, closeWindow
        case save, saveAll, closeTab, reopenTab, nextTab, previousTab, goBack, goForward
        case newTerminal, showProblems
        case quickOpen, commandPalette, goToLine, showSearch
        case showSymbols, showReferences, renameSymbol, formatDocument, quickFix
        case foldCode, unfoldCode
    }

    /// 若当前键盘窗口是 IDE 窗口,执行命令并返回 true;否则返回 false(调用方走 Agent 窗口的默认行为)。
    /// - Parameter command: 命令
    @discardableResult
    func route(_ command: Command) -> Bool {
        guard let model = WindowContext.shared.ideModel else { return false }
        switch command {
        case .toggleSidebar: model.toggleSidebar()
        case .togglePanel: model.togglePanel()
        case .toggleAgentPane: model.toggleAgentPane()
        case .maximizeAgentPane: model.toggleAgentMaximized()
        case .perfHUD: model.perfHUDVisible.toggle()
        case .closeWindow: controllers[model.id]?.window?.performClose(nil)
        case .save: controllers[model.id]?.workspace.saveActive()
        case .saveAll: controllers[model.id]?.workspace.saveAll()
        case .closeTab:
            // 没有可关的标签时(空窗口、固定标签除外)才关闭窗口
            if let workspace = controllers[model.id]?.workspace, !workspace.closeActiveTab(), model.editor.allTabs.isEmpty {
                controllers[model.id]?.window?.performClose(nil)
            }
        case .newTerminal: controllers[model.id]?.workspace.newTerminal()
        case .showProblems: model.showPanel(.problems)
        case .quickOpen: controllers[model.id]?.workspace.openPalette("")
        case .commandPalette: controllers[model.id]?.workspace.openPalette(">")
        case .goToLine: controllers[model.id]?.workspace.openPalette(":")
        case .showSearch: controllers[model.id]?.workspace.perform("view.search")
        case .showSymbols: controllers[model.id]?.workspace.showSymbols()
        case .showReferences: controllers[model.id]?.workspace.showReferences()
        case .renameSymbol: controllers[model.id]?.workspace.renameSymbol()
        case .formatDocument: controllers[model.id]?.workspace.formatDocument()
        case .quickFix: controllers[model.id]?.workspace.showCodeActions()
        case .foldCode: controllers[model.id]?.workspace.perform("edit.fold")
        case .unfoldCode: controllers[model.id]?.workspace.perform("edit.unfold")
        case .reopenTab: controllers[model.id]?.workspace.reopenClosed()
        case .nextTab: controllers[model.id]?.workspace.cycleTab(by: 1)
        case .previousTab: controllers[model.id]?.workspace.cycleTab(by: -1)
        case .goBack: model.goBack()
        case .goForward: model.goForward()
        }
        return true
    }

    // MARK: 生命周期回调

    /// 窗口成为键盘窗口:提升到最近使用首位。
    func windowDidBecomeKey(_ model: IDEWindowModel) {
        registry.activate(model.id)
        // 融合模式:IDE 窗口成为键盘窗口时,工作台当前项目跟随它(两边始终是同一个项目)
        guard FusionMode.shared.isEnabled, let root = model.workspaceRoot else { return }
        let workbench = AppEnvironment.shared.workbench
        if workbench.selectedProjectID != root, workbench.projects.contains(where: { $0.id == root }) { workbench.select(project: root) }
    }

    /// 窗口即将关闭:释放控制器;非退出流程下从注册表移除(退出时保留以便恢复)。
    func windowWillClose(_ model: IDEWindowModel) {
        let id = model.id
        // 控制器在回调栈上,延后到下一轮再释放,避免窗口代理在自己的回调里被销毁
        let controller = controllers.removeValue(forKey: id)
        // 关闭窗口(非退出)时结束它名下的终端:否则 shell 进程与终端视图会一直留在 TerminalStore 里(浸泡基准发现的泄漏)
        if !isTerminating {
            controller?.workspace.closeAllTerminals()
            // 释放本窗口 Agent 面板的专属会话(结束其 Agent 进程),否则每开一个 IDE 窗口就泄漏一个进程
            AppEnvironment.shared.workbench.releaseConversations(ownerPrefix: id.uuidString)
        }
        if !isTerminating { registry.remove(id) }
        Task { @MainActor in withExtendedLifetime(controller) {} }
        Log.app.info("IDE 窗口已关闭", ["id": id.uuidString, "terminating": "\(isTerminating)"])
    }

    /// 应用即将退出:标记并同步落盘。
    func prepareForTermination() {
        isTerminating = true
        registry.saveNow()
    }

    // MARK: 显示

    /// 显示窗口(必要时创建控制器),并记录冷开/热切换耗时。
    private func show(_ model: IDEWindowModel, reason: String, activate: Bool = true, adoptFrame: NSRect? = nil, replacing source: NSWindow? = nil) {
        let cold = controllers[model.id] == nil
        let span = Log.perf.span(cold ? "IDE 窗口冷开" : "IDE 窗口切换", warnMs: cold ? 250 : 50, quiet: true, ["reason": reason])
        let controller: IDEWindowController
        if let existing = controllers[model.id] {
            controller = existing
        } else {
            createdCount += 1
            controller = IDEWindowController(model: model, cascadeIndex: createdCount)
            controllers[model.id] = controller
        }
        NSApp.activate()
        if let window = controller.window {
            if let adoptFrame { window.adoptFusionFrame(adoptFrame) }
            if let source, source !== window { window.beginFusionReveal() }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
            if let source, source !== window { window.finishFusionReveal(replacing: source) }
        }
        span.end(["windows": "\(controllers.count)"])
    }
}

extension NSWindow {
    /// 融合模式:沿用另一个窗口的外框(无动画;外框无效或在全屏时保持原样)。
    /// - Parameter frame: 来源窗口外框
    func adoptFusionFrame(_ frame: NSRect) {
        guard !styleMask.contains(.fullScreen),
              let target = FusionFrame.adopted(frame, minSize: minSize, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        setFrame(target, display: false)
    }
}

extension NSWindow {
    /// 融合模式切换:目标窗口先完全透明地叠在来源窗口上(在 `makeKeyAndOrderFront` 之前调用),
    /// 避免它首帧未渲染完时闪出空白或错位的内容。必须与 `finishFusionReveal(replacing:)` 成对使用。
    func beginFusionReveal() {
        alphaValue = 0
    }

    /// 融合模式切换:等目标窗口完成首帧渲染后淡入,淡入完成再隐藏来源窗口,整个过程来源窗口一直垫在下面,
    /// 视觉上是同一个窗口里的内容原地换成了另一种模式。「减弱动态效果」下无渐变,直接替换。
    /// - Parameter source: 被替换的来源窗口
    func finishFusionReveal(replacing source: NSWindow) {
        contentView?.layoutSubtreeIfNeeded()
        displayIfNeeded()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor [weak self, weak source] in
            // 给 SwiftUI 一个运行循环完成首次布局与绘制(热窗口几乎立即完成)
            try? await Task.sleep(for: .milliseconds(40))
            guard let self else { source?.orderOut(nil); return }
            self.contentView?.layoutSubtreeIfNeeded()
            self.displayIfNeeded()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 1
            }, completionHandler: {
                MainActor.assumeIsolated {
                    self.alphaValue = 1
                    source?.orderOut(nil)
                }
            })
        }
    }
}
