// @author ygw
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
        log.info("工作台状态已加载", ["projects": "\(alive.count)", "selected": selected ?? "-"])
    }

    // MARK: 查询

    public var selectedProject: ProjectEntry? { projects.first { $0.id == selectedProjectID } }

    /// 当前项目的会话模型(尚未创建时为 nil)。
    public var activeSession: SessionModel? { selectedProjectID.flatMap { sessions[$0] } }

    /// 置顶项目在前,其余按最近打开时间排序后的项目列表。
    public var orderedProjects: [ProjectEntry] {
        projects.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.lastOpenedAt > rhs.lastOpenedAt
        }
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
        guard projects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
        ensureSession(for: id)
        scheduleSave()
    }

    /// 移除项目:关闭其会话(不删除磁盘上的任何内容)。
    public func removeProject(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        sessions[id]?.shutdown()
        sessions[id] = nil
        projects.remove(at: index)
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
        sessions[id]?.newConversation()
    }

    /// 在项目下打开历史会话。
    public func openHistory(project id: String, sessionId: String, title: String?) {
        select(project: id)
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
        sessions[id] = model
        if autoConnect { model.connect() }
        return model
    }

    /// 用新的 Agent 替换项目会话(窗口内切换 Agent)。
    public func replaceSession(for id: String, with model: SessionModel) {
        sessions[id]?.shutdown()
        model.onHistoryChanged = { [weak self] history in self?.cacheHistory(history, for: id) }
        sessions[id] = model
        if autoConnect { model.connect() }
    }

    /// 缓存历史会话摘要(每项目最多 30 条)。
    func cacheHistory(_ history: [SessionSummary], for id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let cached = history.prefix(30).map { CachedSession(sessionId: $0.sessionId, title: $0.title, updatedAt: $0.updatedAt) }
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

    public func toggleLeft() { layout.leftVisible.toggle() }
    public func toggleRight() { layout.rightVisible.toggle() }
    public func toggleBottom() { layout.bottomVisible.toggle() }

    /// 显示右栏并切换到某视图。
    public func showRight(_ pane: RightPane) {
        layout.rightPane = pane
        layout.rightVisible = true
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
        do { try store.save(state) } catch { log.error("保存工作台状态失败", error: error, ["file": store.fileURL.path]) }
    }
}
