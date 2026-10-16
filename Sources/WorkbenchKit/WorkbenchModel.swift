// @author ixxxxoooo
// 工作台模型:一个窗口承载多个项目,每个项目按需拉起各自 cwd 的 Agent 会话;布局与项目列表持久化。

import ACPKit
import AgentHost
import ChatKit
import Foundation
import Observation
import OMLog

@MainActor
@Observable
public final class WorkbenchModel {
    public private(set) var projects: [ProjectEntry]
    public private(set) var selectedProjectID: String?
    public var layout: WorkbenchLayout { didSet { if layout != oldValue { scheduleSave() } } }
    /// 每个项目的活动会话(按需创建)
    public private(set) var sessions: [String: SessionModel] = [:]
    /// 主窗口当前显示的内容:工作台或设置整页(不持久化,启动时总是工作台)。
    public var mode: WorkbenchMode = .workspace
    /// 停靠布局:标签组与分屏(持久化)。
    public var dock: DockLayout { didSet { if dock != oldValue { scheduleSave() } } }

    /// 最近关闭的标签(⌘⇧T 恢复,不持久化)。
    @ObservationIgnored private var closedTabs = ClosedTabStack()
    @ObservationIgnored private let store: WorkbenchStore
    @ObservationIgnored private let makeSession: @MainActor (URL) -> SessionModel
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log.session
    @ObservationIgnored private let autoConnect: Bool

    /// - Parameters:
    ///   - store: 状态存取
    ///   - makeSession: 创建会话模型的工厂(应用层在其中接入通知等能力)
    ///   - autoConnect: 创建会话后是否立即预热连接(测试中关闭)
    public init(store: WorkbenchStore = WorkbenchStore(), autoConnect: Bool = true, makeSession: @escaping @MainActor (URL) -> SessionModel) {
        self.autoConnect = autoConnect
        self.store = store
        self.makeSession = makeSession
        let state = store.load() ?? WorkbenchState()
        let alive = state.projects.filter { FileManager.default.fileExists(atPath: $0.id) }
        let selected = alive.contains { $0.id == state.selectedProjectID } ? state.selectedProjectID : alive.first?.id
        projects = alive
        selectedProjectID = selected
        layout = state.layout
        dock = (state.dock ?? DockLayout()).restoredForLaunch(projectIDs: Set(alive.map(\.id)))
        log.info("工作台状态已加载", ["projects": "\(alive.count)", "selected": selected ?? "-"])
    }

    // MARK: 查询

    public var selectedProject: ProjectEntry? { projects.first { $0.id == selectedProjectID } }

    /// 会话模型所属的项目 ID。
    public func projectID(of model: SessionModel) -> String? {
        sessions.first { $0.value === model }?.key
    }

    /// 当前项目的会话模型(尚未创建时为 nil)。
    public var activeSession: SessionModel? { selectedProjectID.flatMap { sessions[$0] } }

    /// 项目排序(对齐 kuku):置顶优先 → 添加时间倒序 → 路径兜底。
    /// 不再按「最近打开」排序:选中/切换项目不会让左栏项目换位。
    public var orderedProjects: [ProjectEntry] {
        projects.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id < rhs.id
        }
    }

    /// 所有项目是否都已折叠(无项目时为 false)。
    public var allProjectsCollapsed: Bool { !projects.isEmpty && projects.allSatisfy(\.collapsed) }

    /// 一键折叠/展开左栏里的所有项目分组。
    /// - Parameter collapsed: true 折叠全部;false 展开全部
    public func setAllProjectsCollapsed(_ collapsed: Bool) {
        guard projects.contains(where: { $0.collapsed != collapsed }) else { return }
        for index in projects.indices { projects[index].collapsed = collapsed }
        scheduleSave()
    }

    /// 解析 ISO8601(含/不含毫秒)时间;使用值类型解析策略,可在任意线程高频调用。
    public nonisolated static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }

    // MARK: 项目

    /// 添加(或选中已存在的)项目并启动其会话。
    /// - Parameter url: 项目目录
    /// - Returns: 项目 ID;目录不存在时为 nil
    @discardableResult
    public func openProject(_ url: URL, now: Date = Date()) -> String? {
        var isDirectory: ObjCBool = false
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            log.warning("打开项目失败:目录不存在", ["path": standardized.path])
            return nil
        }
        let id = standardized.path
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].lastOpenedAt = now
        } else {
            projects.append(ProjectEntry(url: standardized, now: now))
            log.info("添加项目", ["path": id])
        }
        select(project: id)
        RecentStore.recordProject(id)
        return id
    }

    /// 选中项目;会话尚未创建时创建并预热连接。
    public func select(project id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        ensureSession(for: id)
        dock.open(.chat(projectID: id), title: project.name)
        mode = .workspace
        scheduleSave()
    }

    /// 移除项目:关闭其会话(不删除磁盘上的任何内容)。
    public func removeProject(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        sessions[id]?.shutdown()
        sessions[id] = nil
        projects.remove(at: index)
        dock.closeTabs { Self.belongs($0.kind, toProject: id) }
        if selectedProjectID == id { selectedProjectID = orderedProjects.first?.id }
        if let selected = selectedProjectID { ensureSession(for: selected) }
        log.info("移除项目", ["path": id])
        scheduleSave()
    }

    /// 切换置顶。
    public func togglePin(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinned.toggle()
        scheduleSave()
    }

    // MARK: 标签与停靠

    /// 标签内容是否归属某项目(会话/改动按项目 ID,文件/Diff 按路径前缀)。
    static func belongs(_ kind: TabKind, toProject id: String) -> Bool {
        switch kind {
        case .chat(let p), .changes(let p), .subagent(let p, _), .history(let p, _), .agentTerminal(let p, _): return p == id
        case .file(let path), .diff(let path), .blame(let path): return path == id || path.hasPrefix(id + "/")
        case .terminal, .preview: return false
        }
    }

    /// 打开文件标签(单击预览,双击固化)。
    /// - Parameters:
    ///   - path: 绝对路径
    ///   - line: 定位行(1 起)
    ///   - preview: 是否预览方式
    @discardableResult
    public func openFile(_ path: String, line: Int? = nil, preview: Bool = true) -> UUID {
        mode = .workspace
        return dock.open(.file(path: path), title: (path as NSString).lastPathComponent, preview: preview, line: line)
    }

    /// 打开单个文件的差异标签。
    @discardableResult
    public func openDiff(_ path: String) -> UUID {
        mode = .workspace
        return dock.open(.diff(path: path), title: String(localized: "差异") + " · " + (path as NSString).lastPathComponent, preview: true)
    }

    /// 打开子 Agent 的只读完整会话标签。
    /// - Parameters:
    ///   - projectID: 项目
    ///   - toolCallID: 派生子 Agent 的工具调用 ID
    ///   - title: 标签标题
    @discardableResult
    public func openSubagent(project projectID: String, toolCallID: String, title: String) -> UUID {
        mode = .workspace
        return dock.open(.subagent(projectID: projectID, toolCallID: toolCallID), title: title)
    }

    /// 以新标签页打开 Agent 终端的只读输出(任务坞点击行时使用,与普通标签一致进入聚焦组)。
    /// - Parameters:
    ///   - projectID: 项目
    ///   - terminalID: Agent 终端 ID
    ///   - title: 标签标题(通常为命令)
    @discardableResult
    public func openAgentTerminal(project projectID: String, terminalID: String, title: String) -> UUID {
        mode = .workspace
        return dock.open(.agentTerminal(projectID: projectID, terminalID: terminalID), title: title)
    }

    /// 打开预览标签(如放大查看的 Mermaid 图)。
    /// - Parameters:
    ///   - id: 预览内容标识(同一标识复用同一标签)
    ///   - title: 标签标题
    @discardableResult
    public func openPreview(id: String, title: String) -> UUID {
        mode = .workspace
        return dock.open(.preview(id: id), title: title)
    }

    /// 打开终端标签。
    /// - Parameters:
    ///   - id: 终端标识(同一标识复用同一标签)
    ///   - title: 标签标题
    @discardableResult
    public func openTerminal(id: String, title: String) -> UUID {
        mode = .workspace
        return dock.open(.terminal(id: id), title: title)
    }

    /// 打开 Git 提交历史标签。
    /// - Parameters:
    ///   - projectID: 项目
    ///   - path: 仅看该文件的历史;nil 表示整个仓库
    @discardableResult
    public func openHistory(project projectID: String, path: String? = nil) -> UUID {
        mode = .workspace
        let title = path.map { String(localized: "历史") + " · " + ($0 as NSString).lastPathComponent } ?? String(localized: "Git 历史")
        return dock.open(.history(projectID: projectID, path: path), title: title)
    }

    /// 打开文件的逐行追溯(blame)标签。
    @discardableResult
    public func openBlame(_ path: String) -> UUID {
        mode = .workspace
        return dock.open(.blame(path: path), title: "Blame · " + (path as NSString).lastPathComponent)
    }

    /// 关闭某项目全部子 Agent 标签(会话被替换后它们指向的工具调用已不存在)。
    func closeSubagentTabs(in projectID: String) {
        dock.closeTabs { tab in
            switch tab.kind {
            case .subagent(let p, _), .agentTerminal(let p, _): return p == projectID
            default: return false
            }
        }
    }

    /// 打开本轮改动汇总标签。
    @discardableResult
    public func openChanges(project id: String) -> UUID {
        mode = .workspace
        return dock.open(.changes(projectID: id), title: String(localized: "改动"))
    }

    /// 激活标签;会话标签同时切换当前项目。
    public func activateTab(_ id: UUID) {
        dock.activate(id)
        syncSelectionFromDock()
    }

    /// 关闭标签;关闭后焦点落到相邻标签时同步当前项目。记入关闭栈以便 ⌘⇧T 恢复。
    public func closeTab(_ id: UUID) {
        if let tab = dock.tab(id) { closedTabs.push(tab) }
        dock.close(id)
        syncSelectionFromDock()
    }

    /// 重新打开最近关闭的标签(会话标签对应的项目已移除时跳过,继续弹出下一项)。
    /// - Returns: 是否成功恢复了一个标签
    @discardableResult
    public func reopenClosedTab() -> Bool {
        while let closed = closedTabs.pop() {
            if case .chat(let projectID) = closed.kind, !projects.contains(where: { $0.id == projectID }) { continue }
            mode = .workspace
            let id = dock.open(closed.kind, title: closed.title, preview: false, line: closed.line)
            dock.activate(id)
            syncSelectionFromDock()
            return true
        }
        return false
    }

    /// 在聚焦组内切换到第 `number` 个标签(1–9,9 为最后一个)。
    public func selectTab(number: Int) {
        guard let group = dock.focusedGroup, let index = TabNavigation.index(forShortcut: number, count: group.tabs.count) else { return }
        activateTab(group.tabs[index].id)
    }

    /// 在聚焦组内循环切换标签。
    /// - Parameter delta: +1 下一个,-1 上一个
    public func cycleTab(by delta: Int) {
        guard let group = dock.focusedGroup else { return }
        let current = group.tabs.firstIndex { $0.id == group.activeID } ?? 0
        guard let index = TabNavigation.cycled(from: current, delta: delta, count: group.tabs.count) else { return }
        activateTab(group.tabs[index].id)
    }

    /// 聚焦组内激活标签若为会话,则把它所属项目设为当前项目。
    public func syncSelectionFromDock() {
        guard case .chat(let id)? = dock.focusedGroup?.active?.kind, id != selectedProjectID,
              projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        ensureSession(for: id)
        scheduleSave()
    }

    // MARK: 会话置顶与归档

    /// 会话是否已置顶。
    public func isSessionPinned(_ sessionId: String, in project: String) -> Bool {
        projects.first { $0.id == project }?.pinnedSessions.contains(sessionId) ?? false
    }

    /// 会话是否已归档。
    public func isSessionArchived(_ sessionId: String, in project: String) -> Bool {
        projects.first { $0.id == project }?.archivedSessions.contains(sessionId) ?? false
    }

    /// 切换会话置顶(归档的会话置顶时自动取消归档)。
    public func toggleSessionPin(_ sessionId: String, in project: String) {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        if let at = projects[index].pinnedSessions.firstIndex(of: sessionId) {
            projects[index].pinnedSessions.remove(at: at)
        } else {
            projects[index].pinnedSessions.append(sessionId)
            projects[index].archivedSessions.removeAll { $0 == sessionId }
        }
        scheduleSave()
    }

    /// 归档或取消归档会话(归档同时取消置顶)。
    public func setSessionArchived(_ archived: Bool, sessionId: String, in project: String) {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[index].archivedSessions.removeAll { $0 == sessionId }
        if archived {
            projects[index].archivedSessions.append(sessionId)
            projects[index].pinnedSessions.removeAll { $0 == sessionId }
        }
        scheduleSave()
    }

    // MARK: 设置整页

    /// 进入设置整页。
    public func openSettings() { mode = .settings }

    /// 返回工作台。
    public func closeSettings() { mode = .workspace }

    /// 切换项目树节点折叠。
    public func toggleCollapsed(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].collapsed.toggle()
        scheduleSave()
    }

    /// 在项目下开始新对话(选中项目并重置其会话)。
    public func newConversation(in id: String) {
        select(project: id)
        closeSubagentTabs(in: id)
        sessions[id]?.newConversation()
    }

    /// 在项目下打开历史会话。
    public func openHistory(project id: String, sessionId: String, title: String?) {
        select(project: id)
        closeSubagentTabs(in: id)
        guard let model = sessions[id] else { return }
        let summary = model.history.first { $0.sessionId == sessionId } ?? SessionSummary(sessionId: sessionId, cwd: id, title: title)
        model.openSession(summary)
    }

    /// 会话模型创建(幂等)。
    @discardableResult
    public func ensureSession(for id: String) -> SessionModel? {
        if let existing = sessions[id] { return existing }
        guard let project = projects.first(where: { $0.id == id }) else { return nil }
        let model = makeSession(project.url)
        model.onHistoryChanged = { [weak self] history in self?.cacheHistory(history, for: id) }
        model.onAgentEdit = { [weak self] edit in self?.followAgentEdit(edit, project: id) }
        sessions[id] = model
        if autoConnect { model.connect() }
        return model
    }

    /// 是否开启「跟随 Agent」;默认读偏好设置(测试可替换)。
    @ObservationIgnored public var followAgentEnabled: @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: ClientPrefs.Key.editorFollowAgent)
    }

    /// Agent 编辑了文件:开启跟随时在预览标签中打开并定位到首个改动行。
    /// 只跟随当前选中的项目,避免后台项目抢占界面。
    func followAgentEdit(_ edit: AgentEdit, project id: String) {
        guard followAgentEnabled(), selectedProjectID == id else { return }
        openFile(edit.path, line: edit.firstChangedLine, preview: true)
    }

    /// 用新的 Agent 替换项目会话(窗口内切换 Agent)。
    public func replaceSession(for id: String, with model: SessionModel) {
        sessions[id]?.shutdown()
        model.onHistoryChanged = { [weak self] history in self?.cacheHistory(history, for: id) }
        model.onAgentEdit = { [weak self] edit in self?.followAgentEdit(edit, project: id) }
        sessions[id] = model
        if autoConnect { model.connect() }
    }

    /// 缓存历史会话摘要(每项目最多 30 条);为每条会话保留/生成「首次出现时间」作为稳定排序键。
    func cacheHistory(_ history: [SessionSummary], for id: String, now: Date = Date()) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let previous = Dictionary(projects[index].sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let hadCache = !projects[index].sessions.isEmpty
        let nowText = now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let cached = history.prefix(30).map { item -> CachedSession in
            // 首次填充时冻结为更新时间;之后新出现的会话以出现时刻为准(排在最前)
            let first = previous[item.sessionId]?.firstSeenAt ?? (hadCache ? nowText : item.updatedAt)
            return CachedSession(sessionId: item.sessionId, title: item.title, updatedAt: item.updatedAt, firstSeenAt: first)
        }
        guard projects[index].sessions != cached else { return }
        projects[index].sessions = cached
        scheduleSave()
    }

    /// 关闭所有会话(应用退出)。
    public func shutdownAll() {
        for model in sessions.values { model.shutdown() }
        saveNow()
    }

    // MARK: 布局

    // MARK: 标签导航历史(回退/前进)

    /// 标签导航历史(不持久化)。
    public private(set) var nav = NavHistory()

    /// 记录当前聚焦组的激活标签,并清理已关闭标签。视图在激活标签或标签集合变化时调用。
    public func recordNavigation() {
        let alive = Set(dock.allTabs.map(\.id))
        nav.prune(alive: alive)
        if let id = dock.focusedGroup?.activeID, alive.contains(id) { nav.push(id) }
    }

    /// 回退到上一个激活过的标签。
    public func goBack() {
        recordNavigation()
        guard let id = nav.back() else { return }
        activateTab(id)
    }

    /// 前进到下一个标签。
    public func goForward() {
        recordNavigation()
        guard let id = nav.forward() else { return }
        activateTab(id)
    }

    public func toggleLeft() { layout.leftVisible.toggle() }
    public func toggleRight() { layout.rightVisible.toggle() }
    public func toggleBottom() { layout.bottomVisible.toggle() }

    /// 显示右栏并切换到某视图。
    public func showRight(_ pane: RightPane) {
        layout.rightPane = pane
        layout.rightVisible = true
    }

    // MARK: 面板摆放

    /// 项目级常驻终端的标识(与终端存储一致;面板位置变化时进程保持存活)。
    public var residentTerminalID: String { "bottom:" + (selectedProjectID ?? NSHomeDirectory()) }

    /// 编辑区中的常驻终端标签(终端放在编辑区时存在)。
    private var residentTerminalTabs: [WorkbenchTab] {
        dock.allTabs.filter { if case .terminal(let id) = $0.kind { return id.hasPrefix("bottom:") } else { return false } }
    }

    /// 终端当前是否显示在界面上。
    public var isTerminalShown: Bool {
        switch layout.placement.terminal {
        case .bottom: return layout.bottomVisible && layout.bottomPane == .terminal
        case .left, .right: return layout.terminalVisible
        case .editor: return !residentTerminalTabs.isEmpty
        }
    }

    /// 显示终端(按当前摆放位置)。
    public func showTerminal() {
        switch layout.placement.terminal {
        case .bottom: showBottom(.terminal)
        case .left, .right: layout.terminalVisible = true
        case .editor:
            let id = residentTerminalID
            let tab = dock.open(.terminal(id: id), title: String(localized: "终端"))
            mode = .workspace
            dock.activate(tab)
            syncSelectionFromDock()
        }
    }

    /// 隐藏终端(进程保持存活;编辑区终端标签会被关闭,进程仍由终端存储保留)。
    public func hideTerminal() {
        switch layout.placement.terminal {
        case .bottom: layout.bottomVisible = false
        case .left, .right: layout.terminalVisible = false
        case .editor:
            for tab in residentTerminalTabs { dock.close(tab.id) }
            syncSelectionFromDock()
        }
    }

    /// 切换终端显隐(⌘J):终端在底部时与旧行为一致(整个底部面板显隐)。
    public func toggleTerminal() {
        if layout.placement.terminal == .bottom { toggleBottom(); return }
        if isTerminalShown { hideTerminal() } else { showTerminal() }
    }

    /// 把终端移动到新位置:保持其显示状态与进程(终端标识不变),并清理旧位置的残留。
    /// - Parameter target: 目标位置
    public func setTerminalPlacement(_ target: TerminalPlacement) {
        var next = layout.placement
        next.terminal = target
        applyPlacement(next)
    }

    /// 设置项目栏所在侧。
    public func setSidebarSide(_ side: PanelSide) {
        var next = layout.placement
        next.sidebarSide = side
        applyPlacement(next)
    }

    /// 设置工具栏(文件/搜索/Git)所在侧。
    public func setToolsSide(_ side: PanelSide) {
        var next = layout.placement
        next.toolsSide = side
        applyPlacement(next)
    }

    /// 恢复默认布局:终端在底部,项目栏在左,工具栏在右,各面板恢复默认尺寸。
    public func resetLayout() {
        applyPlacement(PanelPlacement())
        layout.leftWidth = PanelMetrics.leftDefault
        layout.rightWidth = PanelMetrics.rightDefault
        layout.terminalWidth = PanelMetrics.terminalDefault
        layout.bottomHeight = 240
    }

    /// 应用新的摆放配置;终端位置变化时迁移其显示状态。
    private func applyPlacement(_ next: PanelPlacement) {
        let wasShown = isTerminalShown
        let old = layout.placement.terminal
        guard next != layout.placement else { return }
        layout.placement = next
        if next.terminal != old {
            // 清理旧位置:编辑区标签关闭(不进入「最近关闭」),底部/侧栏显隐复位
            if old == .editor { for tab in residentTerminalTabs { dock.close(tab.id) } }
            if old == .bottom, layout.bottomPane == .terminal { layout.bottomPane = .output; layout.bottomVisible = false }
            if old.isSide { layout.terminalVisible = false }
            layout.clamp()
            if wasShown { showTerminal() }
            syncSelectionFromDock()
        }
        layout.clamp()
    }

    /// 显示底部面板并切换到某视图。
    public func showBottom(_ pane: BottomPane) {
        layout.bottomPane = pane
        layout.bottomVisible = true
    }

    // MARK: 持久化

    /// 合并短时间内的多次修改后写盘(拖拽分隔条时不会每帧写文件)。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// 立即写盘。
    public func saveNow() {
        saveTask?.cancel()
        var state = WorkbenchState()
        state.layout = layout
        state.projects = projects
        state.selectedProjectID = selectedProjectID
        state.dock = dock
        do { try store.save(state) } catch { log.error("保存工作台状态失败", error: error, ["file": store.fileURL.path]) }
    }
}
