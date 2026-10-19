// @author ixxxxoooo
// 应用级动作桥:把 SwiftUI 的 openWindow / openSettings 暴露给 AppKit 代码(托盘、通知点击),
// 并承载「打开某个会话」的跨窗口请求。

import ChatKit
import OMLog
import SwiftUI

/// 打开会话请求。
struct SessionOpenRequest: Equatable {
    var workspacePath: String
    var sessionId: String?
    var title: String?
    var nonce = UUID()
}

@MainActor
@Observable
final class AppActions {
    static let shared = AppActions()

    /// 待处理的会话打开请求(由对应工作区窗口消费)
    var sessionRequest: SessionOpenRequest?

    /// 主窗口(由工作台视图登记;窗口关闭后系统会释放它)
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var openWindowAction: OpenWindowAction?

    /// 由窗口视图捕获环境动作。
    func capture(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    /// 把目录加入工作台(已存在则选中)并前置主窗口。
    func openWorkspace(_ url: URL) {
        Log.app.info("打开项目", ["path": url.path])
        AppEnvironment.shared.workbench.openProject(url)
        showMainWindow()
    }

    /// 重新启动应用:先拉起一个等待当前进程退出后再打开应用包的后台 shell,然后正常退出
    /// (退出流程会清理 Agent 子进程与持久化状态)。非 `.app` 包形态(如 `swift run`)下无法重启,仅记录日志。
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            Log.ui.warning("非应用包形态,无法重启", ["path": bundleURL.lastPathComponent])
            return
        }
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        do {
            try process.run()
            Log.ui.info("应用重启已安排")
            NSApp.terminate(nil)
        } catch {
            Log.ui.error("拉起重启脚本失败", ["error": "\(error)"])
        }
    }

    /// 打开设置整页(并入主窗口,可深链到某页)。
    func openSettings(page: SettingsPage? = nil) {
        // 扩展类页面(MCP/技能/子 Agent/Hooks/插件/记忆)已合并进侧栏「自定义」页:深链改为打开它并预选类型
        if let page, let filter = CustomizeFilter.from(page: page) {
            AppEnvironment.shared.workbench.openCustomize(filter: filter.rawValue)
            showMainWindow()
            return
        }
        if let page { SettingsRouter.shared.go(page) }
        AppEnvironment.shared.workbench.openSettings()
        showMainWindow()
    }

    /// 删除会话:确认 → 客户端移除(缓存/置顶/归档/标签 + 墓碑)→ 引擎支持时同步删除其历史。
    /// 引擎侧用**会话所属引擎**的连接删除;没有对应连接时只做本地移除(墓碑保证它不再回到侧栏)。
    /// - Parameters:
    ///   - projectID: 项目 ID
    ///   - sessionId: 协议会话 ID
    ///   - title: 标题(确认框展示)
    ///   - agentID: 会话所属引擎(nil 取缓存登记的归属)
    func deleteSession(projectID: String, sessionId: String, title: String, agentID: String?) {
        let workbench = AppEnvironment.shared.workbench
        let models = workbench.conversations.filter { $0.key.projectID == projectID }.map(\.value)
        let running = models.contains { $0.sessionId == sessionId && $0.isRunning }
        let message = running
            ? String(localized: "「\(title)」正在运行,删除会立即中断它,且无法恢复。")
            : String(localized: "「\(title)」将被永久删除,无法恢复。")
        guard OMDialog.confirm(title: String(localized: "删除会话"), message: message, confirmTitle: String(localized: "删除"), destructive: true) else { return }
        let owner = agentID ?? workbench.cachedAgentID(ofSession: sessionId, in: projectID)
        // 休眠中的连接也可用(删除前会自动唤醒),但优先用已就绪的旁观连接,免得为删除专门唤醒进程
        func matches(_ model: SessionModel) -> Bool { model.isAvailable && (owner == nil || model.descriptor.id == owner) }
        let bystanders = models.filter { $0.sessionId != sessionId && matches($0) }
        let bystander = bystanders.first { $0.phase == .ready } ?? bystanders.first
        let displaying = models.first { $0.sessionId == sessionId && matches($0) }
        RecentStore.removeSession(sessionId)
        if let bystander {
            workbench.forgetSession(sessionId, in: projectID)
            Task { _ = await bystander.deleteOnEngine(sessionId) }
        } else if let displaying {
            // 只有正显示它的连接能删:先让引擎删(最多等 3 秒;休眠中需要先唤醒,最多等 10 秒),再关闭标签
            let wait: Duration = displaying.isHibernated ? .seconds(10) : .seconds(3)
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = await displaying.deleteOnEngine(sessionId) }
                    group.addTask { try? await Task.sleep(for: wait) }
                    await group.next()
                    group.cancelAll()
                }
                workbench.forgetSession(sessionId, in: projectID)
            }
        } else {
            workbench.forgetSession(sessionId, in: projectID)
            Log.session.info("删除会话:无对应引擎连接,仅本地移除", ["project": projectID, "owner": owner ?? "-"])
        }
    }

    /// 回到对话并把文本追加到当前会话的输入框(设置页里的「在对话中使用」)。
    /// - Parameter text: 要插入的文本(如 `/review ` 或 `@agent-explorer `)
    func insertIntoComposer(_ text: String) {
        let workbench = AppEnvironment.shared.workbench
        workbench.closeSettings()
        guard let id = workbench.selectedProjectID, let model = workbench.sessions[id] else { return }
        let separator = model.draft.isEmpty || model.draft.hasSuffix(" ") || model.draft.hasSuffix("\n") ? "" : " "
        model.draft += separator + text
        showMainWindow()
    }

    /// 把所有文件标签的「未保存」标记与文档状态对齐(保存/重新载入后调用)。
    func refreshDirtyFlags() {
        let workbench = AppEnvironment.shared.workbench
        for tab in workbench.dock.allTabs {
            if case .file(let path) = tab.kind {
                workbench.dock.setDirty(FileDocumentStore.shared.documents[path]?.isDirty ?? false, for: tab.id)
            }
        }
    }

    /// 保存当前聚焦标签对应的文件。
    func saveActiveFile() {
        let workbench = AppEnvironment.shared.workbench
        guard case .file(let path)? = workbench.dock.focusedGroup?.active?.kind else { return }
        Task { _ = await FileDocumentStore.shared.save(path); refreshDirtyFlags() }
    }

    /// 保存所有未保存的文件。
    func saveAllFiles() {
        Task { _ = await FileDocumentStore.shared.saveAll(); refreshDirtyFlags() }
    }

    /// 是否存在可保存的当前文件(供菜单启用状态)。
    var canSaveActiveFile: Bool {
        guard case .file(let path)? = AppEnvironment.shared.workbench.dock.focusedGroup?.active?.kind else { return false }
        return FileDocumentStore.shared.documents[path]?.isDirty ?? false
    }

    /// ⌘W:关闭聚焦组的当前标签;固定标签不关闭;没有任何标签时才关闭窗口。
    func closeActiveTabOrWindow() {
        let workbench = AppEnvironment.shared.workbench
        if let tab = workbench.dock.focusedGroup?.active {
            if !tab.isPinned { requestCloseTab(tab.id) }
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// 请求关闭标签:文件有未保存修改时询问「保存 / 不保存 / 取消」。
    func requestCloseTab(_ id: UUID) {
        let workbench = AppEnvironment.shared.workbench
        guard let tab = workbench.dock.tab(id) else { return }
        guard case .file(let path) = tab.kind, let doc = FileDocumentStore.shared.documents[path], doc.isDirty else {
            workbench.closeTab(id)
            return
        }
        let choice = OMDialog.show(
            title: String(localized: "要保存对 \((path as NSString).lastPathComponent) 的修改吗?"),
            message: String(localized: "如果不保存,你的修改将会丢失。"),
            buttons: [.cancel(), .destructive(String(localized: "不保存")), .primary(String(localized: "保存"))]
        ).index
        switch choice {
        case 2:
            Task {
                if await FileDocumentStore.shared.save(path) { FileDocumentStore.shared.discard(path); workbench.closeTab(id) }
            }
        case 1:
            FileDocumentStore.shared.discard(path)
            workbench.closeTab(id)
        default: break
        }
    }

    /// 依次关闭一批标签;含未保存文件的标签会逐个询问(取消只影响那一个)。
    /// - Parameter ids: 标签 ID 列表
    func requestCloseTabs(_ ids: [UUID]) {
        for id in ids { requestCloseTab(id) }
    }

    /// 在当前项目目录新建终端标签。
    func openTerminal() {
        let workbench = AppEnvironment.shared.workbench
        let directory = TerminalPrefs.load().startDirectoryPath(project: workbench.selectedProjectID)
        let id = UUID().uuidString
        TerminalStore.shared.register(id: id, directory: directory)
        let index = workbench.dock.allTabs.filter { if case .terminal = $0.kind { return true } else { return false } }.count + 1
        workbench.openTerminal(id: id, title: String(localized: "终端") + (index > 1 ? " \(index)" : ""))
        showMainWindow()
    }

    /// 新建终端(⌃⇧`):终端在编辑区时新开一个终端标签;在底部/左右栏时显示面板并新增一个终端实例。
    func newTerminal() {
        let workbench = AppEnvironment.shared.workbench
        let root = workbench.selectedProjectID ?? NSHomeDirectory()
        workbench.showTerminal()
        if TerminalPanelStore.shared.addTerminal(root: root) == nil {
            OMDialog.alert(title: String(localized: "终端数量已达上限"), message: String(localized: "请先关闭不用的终端再新建。"))
        }
        showMainWindow()
    }

    /// 切换到相邻的终端实例(仅面板内的多终端)。
    /// - Parameter step: 1 下一个,-1 上一个
    func cycleTerminal(_ step: Int) {
        let workbench = AppEnvironment.shared.workbench
        workbench.showTerminal()
        TerminalPanelStore.shared.cycle(step, root: workbench.selectedProjectID ?? NSHomeDirectory())
    }

    /// 在终端面板里只读查看 Agent 的终端(后台命令的实时输出)。终端放在编辑区时退回只读标签页。
    /// - Parameters:
    ///   - session: Agent 终端会话
    ///   - model: 该终端所属的会话
    func viewAgentTerminal(_ session: TerminalSession, model: SessionModel) {
        let workbench = AppEnvironment.shared.workbench
        if workbench.layout.placement.terminal == .editor {
            if let project = workbench.projectID(of: model) ?? workbench.selectedProjectID {
                workbench.openAgentTerminal(project: project, terminalID: session.id, title: session.command)
            }
        } else {
            workbench.showTerminal()
            AgentTerminalStore.shared.open(session, root: workbench.selectedProjectID ?? NSHomeDirectory())
        }
        showMainWindow()
    }

    /// 关闭当前终端实例(最后一个被关闭时隐藏面板)。
    func closeActiveTerminal() {
        let workbench = AppEnvironment.shared.workbench
        guard workbench.isTerminalShown else { return }
        let root = workbench.selectedProjectID ?? NSHomeDirectory()
        let store = TerminalPanelStore.shared
        if store.close(store.state(for: root).activeID, root: root) == .closedLast { workbench.hideTerminal() }
    }

    /// 打开预览标签(如放大的 Mermaid 图)。
    func openPreview(id: String, title: String) {
        AppEnvironment.shared.workbench.openPreview(id: id, title: title)
        showMainWindow()
    }

    /// 打开某个会话(点击通知或托盘菜单):选中项目并请求切换到会话。
    func openSession(workspacePath: String, sessionId: String?, title: String?, uid: String? = nil) {
        Log.app.info("请求打开会话", ["workspace": workspacePath, "session": sessionId ?? "-"])
        if let uid { AttentionCenter.shared.markRead(uid) }
        guard AppEnvironment.shared.workbench.openProject(URL(fileURLWithPath: workspacePath)) != nil else { return }
        sessionRequest = SessionOpenRequest(workspacePath: workspacePath, sessionId: sessionId, title: title)
        showMainWindow()
    }

    /// 在当前项目下开始新对话并前置主窗口。
    func newConversation() {
        AppEnvironment.shared.workbench.newConversationInContext()
        showMainWindow()
    }

    /// 前置主窗口;窗口已被关闭时重新打开。
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }
}
