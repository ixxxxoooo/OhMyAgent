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
        CodeEditorView.goToLineHandler = { [weak self] in self?.route(.goToLine) }
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

    // MARK: 打开与切换

    /// 打开(或聚焦)某根目录的 IDE 窗口。
    /// - Parameters:
    ///   - root: 工作区根目录;nil 为空窗口
    ///   - forceNew: 强制新开
    /// - Returns: 窗口模型
    @discardableResult
    func open(root: String?, forceNew: Bool = false) -> IDEWindowModel {
        let (model, _) = registry.open(root: root, forceNew: forceNew)
        show(model, reason: "open")
        return model
    }

    /// Agent → IDE:聚焦当前项目的 IDE 窗口,没有就新建。
    /// - Parameter forceNew: ⌥ 点击强制新开
    func switchToIDE(forceNew: Bool = false) {
        let root = AppEnvironment.shared.workbench.selectedProject?.id
        open(root: root, forceNew: forceNew)
    }

    /// IDE → Agent:前置 Agent 窗口,并选中该 IDE 窗口对应的项目(项目不在工作台时加入)。
    func switchToAgent() {
        let span = Log.perf.span("IDE 切换到 Agent", warnMs: 50, quiet: true)
        let workbench = AppEnvironment.shared.workbench
        if case .ide(let id) = WindowContext.shared.kind, let root = registry.window(id: id)?.workspaceRoot {
            if workbench.projects.contains(where: { $0.id == root }) {
                if workbench.selectedProjectID != root { workbench.select(project: root) }
            } else {
                workbench.openProject(URL(fileURLWithPath: root))
            }
        }
        AppActions.shared.showMainWindow()
        span.end()
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
    func restoreWindows() {
        let models = registry.windows
        guard !models.isEmpty else { return }
        Log.app.info("恢复 IDE 窗口", ["count": "\(models.count)"])
        for model in models.reversed() { show(model, reason: "restore", activate: model === models.first) }
    }

    // MARK: 命令路由

    /// 在 IDE 窗口里可被菜单/快捷键派发的命令。
    enum Command {
        case toggleSidebar, togglePanel, toggleAgentPane, closeWindow
        case save, saveAll, closeTab, reopenTab, nextTab, previousTab
        case newTerminal, showProblems
        case quickOpen, commandPalette, goToLine, showSearch
        case showSymbols, showReferences, renameSymbol, formatDocument
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
        case .reopenTab: controllers[model.id]?.workspace.reopenClosed()
        case .nextTab: controllers[model.id]?.workspace.cycleTab(by: 1)
        case .previousTab: controllers[model.id]?.workspace.cycleTab(by: -1)
        }
        return true
    }

    // MARK: 生命周期回调

    /// 窗口成为键盘窗口:提升到最近使用首位。
    func windowDidBecomeKey(_ model: IDEWindowModel) {
        registry.activate(model.id)
    }

    /// 窗口即将关闭:释放控制器;非退出流程下从注册表移除(退出时保留以便恢复)。
    func windowWillClose(_ model: IDEWindowModel) {
        let id = model.id
        // 控制器在回调栈上,延后到下一轮再释放,避免窗口代理在自己的回调里被销毁
        let controller = controllers.removeValue(forKey: id)
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
    private func show(_ model: IDEWindowModel, reason: String, activate: Bool = true) {
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
            if window.isMiniaturized { window.deminiaturize(nil) }
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        }
        span.end(["windows": "\(controllers.count)"])
    }
}
