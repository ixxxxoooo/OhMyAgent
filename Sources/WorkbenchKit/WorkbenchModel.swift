// @author ixxxxoooo
// 工作台模型:一个窗口承载多个项目,每个项目按需拉起各自 cwd 的 Agent 会话;布局与项目列表持久化。

import ACPKit
import AgentHost
import ChatKit
import Foundation
import Observation
import OMLog

/// 会话的身份:项目 + 会话标签槽位(槽位 nil 为旧版本的项目主会话)。
public struct ConversationKey: Hashable, Sendable {
    public let projectID: String
    public let slot: String?

    public init(projectID: String, slot: String?) {
        self.projectID = projectID
        self.slot = slot
    }
}

@MainActor
@Observable
public final class WorkbenchModel {
    public private(set) var projects: [ProjectEntry]
    public private(set) var selectedProjectID: String?
    public var layout: WorkbenchLayout { didSet { if layout != oldValue { scheduleSave() } } }
    /// 全部会话:每个会话标签对应一个独立的 SessionModel(按需创建,标签关闭时回收)
    public private(set) var conversations: [ConversationKey: SessionModel] = [:]
    /// 每个项目最近一次激活的会话槽位(决定「项目当前会话」)
    public private(set) var lastSlot: [String: String?] = [:]
    /// 主窗口当前显示的内容:工作台或设置整页(不持久化,启动时总是工作台)。
    public var mode: WorkbenchMode = .workspace
    /// 停靠布局:标签组与分屏(持久化)。
    public var dock: DockLayout { didSet { if dock != oldValue { reapConversations(); recordNavigation(); scheduleSave() } } }

    /// 最近关闭的标签(⌘⇧T 恢复,不持久化)。
    @ObservationIgnored private var closedTabs = ClosedTabStack()
    @ObservationIgnored private let store: WorkbenchStore
    @ObservationIgnored private let makeSession: @MainActor (URL) -> SessionModel
    /// 按 Agent ID 创建会话模型的工厂(应用层注入):打开其他引擎的历史会话时,用原引擎承载。
    /// 引擎预热池:切换/打开其他引擎时优先认领已连好的待命会话。
    @ObservationIgnored public let warmPool = EngineWarmPool()
    /// 选中项目变化回调(应用层据此安排预热)。
    @ObservationIgnored public var onProjectSelected: (@MainActor (String) -> Void)?
    @ObservationIgnored public var makeAgentSession: (@MainActor (URL, String) -> SessionModel?)?
    /// 默认引擎 ID(应用层注入):新会话优先认领它的待命会话,实现「新对话/打开历史几乎零等待」。
    @ObservationIgnored public var defaultAgentID: (@MainActor () -> String?)?
    /// 待命会话被认领后回调(应用层据此补充新的待命会话)。
    @ObservationIgnored public var onWarmSessionTaken: (@MainActor () -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 启动时从状态文件读到、尚未创建会话的标签记录:首次显示该标签时据此恢复原会话
    @ObservationIgnored private var pendingRestores: [ConversationKey: ChatSlotRecord] = [:]
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
        // 会话区的目录由应用自己维护(缺失时在首次使用时重建),不能因为目录暂时不存在就丢掉它的历史缓存
        let alive = state.projects.filter { $0.isChatArea || FileManager.default.fileExists(atPath: $0.id) }
        let selected = alive.contains { $0.id == state.selectedProjectID } ? state.selectedProjectID : alive.first { !$0.isChatArea }?.id
        projects = alive
        selectedProjectID = selected
        layout = state.layout
        let aliveIDs = Set(alive.map(\.id))
        let records = (state.chatSlots ?? []).filter { aliveIDs.contains($0.projectID) && !$0.sessionId.isEmpty }
        pendingRestores = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        dock = (state.dock ?? DockLayout()).restoredForLaunch(projectIDs: aliveIDs, keepChats: Set(pendingRestores.keys))
        self.healSessionCreationDates()
        log.info("工作台状态已加载", ["projects": "\(alive.count)", "selected": selected ?? "-"])
    }

    // MARK: 查询

    /// 当前选中的**真实项目**(选中的是会话区时为 nil:文件树、Git、搜索等项目能力据此显示空态)。
    public var selectedProject: ProjectEntry? { projects.first { $0.id == selectedProjectID && !$0.isChatArea } }

    /// 当前选中的条目(含会话区)。
    public var selectedEntry: ProjectEntry? { projects.first { $0.id == selectedProjectID } }

    /// 真实项目列表(不含会话区)。
    public var workspaceProjects: [ProjectEntry] { projects.filter { !$0.isChatArea } }

    /// 当前选中的是否为会话区。
    public var isChatAreaSelected: Bool { selectedEntry?.isChatArea ?? false }

    /// 会话模型所属的项目 ID。
    public func projectID(of model: SessionModel) -> String? {
        conversations.first { $0.value === model }?.key.projectID
    }

    /// 每个项目的「当前会话」:该项目最近激活的会话标签对应的会话;没有记录时取任意一个。
    public var sessions: [String: SessionModel] {
        var result: [String: SessionModel] = [:]
        for (key, model) in conversations {
            if let slot = lastSlot[key.projectID], ConversationKey(projectID: key.projectID, slot: slot) == key {
                result[key.projectID] = model
            } else if result[key.projectID] == nil {
                result[key.projectID] = model
            }
        }
        return result
    }

    /// 所有会话模型(含后台标签里的)。
    public var allSessions: [SessionModel] { Array(conversations.values) }

    /// 当前项目的当前会话(尚未创建时为 nil)。
    public var activeSession: SessionModel? { selectedProjectID.flatMap { sessions[$0] } }

    /// 标签对应的会话(非会话标签或尚未创建时为 nil)。
    public func session(forTab tab: WorkbenchTab) -> SessionModel? {
        guard case .chat(let projectID, let slot) = tab.kind else { return nil }
        return conversations[ConversationKey(projectID: projectID, slot: slot)]
    }

    /// 回收没有标签承载的会话(标签被关闭、项目被移除后调用);运行中的轮次随进程一起结束。
    private func reapConversations() {
        guard !conversations.isEmpty else { return }
        let alive = Set(dock.allTabs.compactMap { tab -> ConversationKey? in
            if case .chat(let projectID, let slot) = tab.kind { return ConversationKey(projectID: projectID, slot: slot) }
            return nil
        })
        for key in conversations.keys where !alive.contains(key) {
            conversations[key]?.shutdown()
            conversations[key] = nil
            if let slot = lastSlot[key.projectID], ConversationKey(projectID: key.projectID, slot: slot) == key { lastSlot[key.projectID] = nil }
            log.info("回收会话", ["project": key.projectID, "slot": key.slot ?? "-"])
        }
    }

    /// 项目排序(对齐 kuku):置顶优先 → 添加时间倒序 → 路径兜底。
    /// 不再按「最近打开」排序:选中/切换项目不会让左栏项目换位。
    public var orderedProjects: [ProjectEntry] {
        workspaceProjects.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            return lhs.id < rhs.id
        }
    }

    /// 所有项目是否都已折叠(无项目时为 false)。
    public var allProjectsCollapsed: Bool { !workspaceProjects.isEmpty && workspaceProjects.allSatisfy(\.collapsed) }

    /// 一键折叠/展开左栏里的所有项目分组。
    /// - Parameter collapsed: true 折叠全部;false 展开全部
    public func setAllProjectsCollapsed(_ collapsed: Bool) {
        guard workspaceProjects.contains(where: { $0.collapsed != collapsed }) else { return }
        for index in projects.indices where !projects[index].isChatArea { projects[index].collapsed = collapsed }
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
        // 托盘/通知用会话区目录打开会话:走会话区自己的入口,避免被当成普通项目登记
        if id == chatAreaURL.standardizedFileURL.path {
            guard let chatID = ensureChatArea(now: now) else { return nil }
            select(project: chatID)
            return chatID
        }
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

    /// 把一个 Git 工作树登记为项目(带 `WorktreeLink`)并选中;侧栏会显示分支徽标。
    /// - Parameters:
    ///   - path: 工作树目录
    ///   - link: 与原项目的关联
    ///   - name: 显示名(通常为「原项目 · 任务名」)
    /// - Returns: 项目 ID;目录不存在时为 nil
    @discardableResult
    public func openWorktreeProject(path: String, link: WorktreeLink, name: String, now: Date = Date()) -> String? {
        guard let id = openProject(URL(fileURLWithPath: path), now: now),
              let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        projects[index].worktree = link
        projects[index].name = name
        scheduleSave()
        return id
    }

    /// 工作树项目对应的原项目;不是工作树或原项目已移除时为 nil。
    /// - Parameter id: 工作树项目 ID
    public func worktreeOrigin(of id: String) -> ProjectEntry? {
        guard let link = projects.first(where: { $0.id == id })?.worktree else { return nil }
        return projects.first { $0.id == link.origin }
    }

    /// 项目当前应显示的会话槽位:最近激活的;否则编辑区里已有的该项目会话标签;都没有时为 nil(主会话)。
    private func preferredSlot(for id: String) -> String? {
        if let slot = lastSlot[id], dock.tab(for: .chat(projectID: id, slot: slot)) != nil { return slot }
        // 启动恢复:优先落在聚焦组里本来就激活着的该项目会话标签
        if case .chat(let p, let slot)? = dock.focusedGroup?.active?.kind, p == id { return slot }
        for tab in dock.allTabs {
            if case .chat(let p, let slot) = tab.kind, p == id { return slot }
        }
        return nil
    }

    /// 选中项目:显示它最近使用的会话标签,没有时创建一个并预热连接。
    public func select(project id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        let slot = preferredSlot(for: id)
        let tab = dock.open(.chat(projectID: id, slot: slot), title: project.name)
        dock.activate(tab)
        lastSlot[id] = .some(slot)
        ensureSession(project: id, slot: slot)
        mode = .workspace
        warmPool.discardAll(except: project.url.path)
        onProjectSelected?(id)
        scheduleSave()
    }

    /// 移除项目:关闭其会话(不删除磁盘上的任何内容)。
    public func removeProject(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: index)
        warmPool.discard(workspace: removed.url.path)
        let folders = [id] + removed.extraFolders
        dock.closeTabs { tab in folders.contains { Self.belongs(tab.kind, toProject: $0) } }
        for key in conversations.keys where key.projectID == id {
            conversations[key]?.shutdown()
            conversations[key] = nil
        }
        lastSlot[id] = nil
        if selectedProjectID == id { selectedProjectID = orderedProjects.first?.id }
        if let selected = selectedProjectID { select(project: selected) }
        log.info("移除项目", ["path": id])
        scheduleSave()
    }

    /// 切换置顶。
    public func togglePin(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinned.toggle()
        scheduleSave()
    }

    // MARK: 会话区(无项目的通用对话)

    /// 会话区的工作目录:状态文件同级的 `Chats` 空目录(演示模式下随沙盒隔离)。
    public var chatAreaURL: URL { store.fileURL.deletingLastPathComponent().appendingPathComponent("Chats", isDirectory: true) }

    /// 会话区条目的 ID(尚未使用过时为 nil)。
    public var chatAreaID: String? { projects.first { $0.isChatArea }?.id }

    /// 会话区追加给 Agent 的系统提示:像 ChatGPT 一样直接用文字回答,不碰文件与命令。
    public nonisolated static let chatAreaPrompt = """
    你现在处于「会话区」:没有打开任何项目,工作目录是一个空的临时目录。请像通用对话助手一样直接用文字回答问题,\
    使用 Markdown 排版,回答语言跟随用户的提问。除非用户明确要求,不要读写文件、执行命令或联网搜索。
    """

    /// 确保会话区条目与目录存在(幂等)。
    /// - Returns: 会话区 ID;目录无法创建时为 nil
    @discardableResult
    public func ensureChatArea(now: Date = Date()) -> String? {
        let url = chatAreaURL.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            log.error("创建会话区目录失败", error: error, ["path": url.path])
            return nil
        }
        if let existing = chatAreaID { return existing }
        var entry = ProjectEntry(url: url, now: now)
        entry.name = String(localized: "会话")
        entry.isChatArea = true
        projects.append(entry)
        log.info("创建会话区", ["path": url.path])
        scheduleSave()
        return entry.id
    }

    /// 某工作目录是否就是会话区的目录。
    public func isChatAreaWorkspace(_ url: URL) -> Bool {
        guard let id = chatAreaID else { return false }
        return id == url.standardizedFileURL.path
    }

    /// 在会话区开始一次新对话(不需要打开项目;当前会话区标签仍是空白时直接复用)。
    public func newGeneralConversation() {
        guard let id = ensureChatArea() else { return }
        newConversation(in: id)
    }

    /// 新对话的落点:选中项目时在该项目下,否则(无项目或停在会话区)在会话区。
    public func newConversationInContext() {
        if let project = selectedProject { newConversation(in: project.id) } else { newGeneralConversation() }
    }

    // MARK: 标签与停靠

    /// 标签内容是否归属某项目(会话/改动按项目 ID,文件/Diff 按路径前缀)。
    static func belongs(_ kind: TabKind, toProject id: String) -> Bool {
        switch kind {
        case .chat(let p, _), .changes(let p), .subagent(let p, _), .history(let p, _), .agentTerminal(let p, _): return p == id
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
            if case .chat(let projectID, _) = closed.kind, !projects.contains(where: { $0.id == projectID }) { continue }
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
        guard case .chat(let id, let slot)? = dock.focusedGroup?.active?.kind, projects.contains(where: { $0.id == id }) else { return }
        let changed = id != selectedProjectID || lastSlot[id] != .some(slot)
        selectedProjectID = id
        lastSlot[id] = .some(slot)
        ensureSession(project: id, slot: slot)
        if changed { scheduleSave() }
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

    /// 重命名会话:标题写入客户端偏好(适配器没有改名接口),并同步缓存与已打开的会话。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - project: 项目 ID
    ///   - title: 新标题(去除首尾空白后不能为空)
    public func renameSession(_ sessionId: String, in project: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, !clean.isEmpty, let index = projects.firstIndex(where: { $0.id == project }) else { return }
        ClientPrefs.setSessionTitle(clean, for: sessionId)
        if let at = projects[index].sessions.firstIndex(where: { $0.sessionId == sessionId }) { projects[index].sessions[at].title = clean }
        for (key, model) in conversations where key.projectID == project { model.applyRenamedTitle(clean, sessionId: sessionId) }
        for tab in dock.allTabs {
            if case .chat(let p, let slot) = tab.kind, p == project, conversations[ConversationKey(projectID: p, slot: slot)]?.sessionId == sessionId {
                dock.setTitle(clean, for: tab.id)
            }
        }
        scheduleSave()
    }

    /// 批量归档会话(归档同时取消置顶)。
    /// - Parameters:
    ///   - sessionIds: 会话 ID 列表
    ///   - project: 项目 ID
    public func archiveSessions(_ sessionIds: [String], in project: String) {
        guard let index = projects.firstIndex(where: { $0.id == project }) else { return }
        var seen = Set<String>()
        let ordered = sessionIds.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ordered.isEmpty else { return }
        let ids = Set(ordered)
        projects[index].archivedSessions.removeAll { ids.contains($0) }
        projects[index].archivedSessions.append(contentsOf: ordered)
        projects[index].pinnedSessions.removeAll { ids.contains($0) }
        scheduleSave()
    }

    /// 归档某项目下的全部会话(包含已缓存与当前打开的,当前空白对话除外)。
    public func archiveAllSessions(in project: String) {
        guard let entry = projects.first(where: { $0.id == project }) else { return }
        var ids = entry.sessions.map(\.sessionId)
        for (key, model) in conversations where key.projectID == project { if let id = model.sessionId { ids.append(id) } }
        var seen = Set<String>()
        archiveSessions(ids.filter { seen.insert($0).inserted }, in: project)
    }

    /// 修改项目在侧栏中显示的名称(不改磁盘上的目录名)。
    /// - Parameters:
    ///   - id: 项目 ID
    ///   - name: 新名称(去除首尾空白后不能为空)
    public func renameProject(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = clean
        scheduleSave()
    }

    // MARK: 项目图标

    /// 图标图片目录:与状态文件同级的 `ProjectIcons`(演示模式因状态文件隔离而自动隔离)。
    public var projectIconDirectory: URL {
        store.fileURL.deletingLastPathComponent().appendingPathComponent("ProjectIcons", isDirectory: true)
    }

    /// 设置(或清除)项目图标;替换掉旧的图片图标时删除旧文件。
    /// - Parameters:
    ///   - icon: 新图标;nil 恢复默认
    ///   - id: 项目 ID
    public func setProjectIcon(_ icon: ProjectIcon?, for id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].icon != icon else { return }
        let old = projects[index].icon
        projects[index].icon = icon
        if old?.kind == .image, old != icon { ProjectIconFiles.removeFile(for: old, in: projectIconDirectory) }
        scheduleSave()
    }

    /// 导入图片作为图标(复制到图标目录)。
    /// - Returns: 成功返回图片图标(尚未应用到任何项目)
    public func importProjectIcon(imageAt url: URL) -> ProjectIcon? {
        ProjectIconFiles.importImage(from: url, into: projectIconDirectory)
    }

    // MARK: 多文件夹工作区

    /// 工作区的全部根目录(主目录在前);项目不存在时为空。
    public func allRoots(of id: String) -> [String] {
        projects.first(where: { $0.id == id })?.allRoots ?? []
    }

    /// 给工作区添加一个附加文件夹。已打开的会话需重新建立才会让 Agent 获得新目录的访问范围。
    /// - Parameters:
    ///   - path: 文件夹路径
    ///   - id: 项目 ID
    /// - Returns: 成功返回规范化路径;失败给出原因
    @discardableResult
    public func addFolder(_ path: String, to id: String, requireExists: Bool = true) -> Result<String, WorkspaceFolderError> {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return .failure(.notDirectory) }
        let result = WorkspaceFolders.validate(path, primary: id, existing: projects[index].extraFolders, requireExists: requireExists)
        if case .success(let normalized) = result {
            projects[index].extraFolders.append(normalized)
            workspaceFoldersChanged(project: id)
            log.info("工作区添加文件夹", ["project": id, "folder": normalized])
        }
        return result
    }

    /// 从工作区移除一个附加文件夹(只改工作区配置,不动磁盘)。
    /// - Parameters:
    ///   - path: 文件夹路径
    ///   - id: 项目 ID
    public func removeFolder(_ path: String, from id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }), projects[index].extraFolders.contains(path) else { return }
        projects[index].extraFolders.removeAll { $0 == path }
        workspaceFoldersChanged(project: id)
        log.info("工作区移除文件夹", ["project": id, "folder": path])
    }

    /// 附加文件夹变化后:刷新会话参数、丢弃不含新目录的待命会话、保存。
    private func workspaceFoldersChanged(project id: String) {
        let extras = projects.first(where: { $0.id == id })?.extraFolders ?? []
        for (key, model) in conversations where key.projectID == id { model.additionalDirectories = extras }
        warmPool.discard(workspace: id)
        scheduleSave()
    }

    /// 领取预热会话;带附加文件夹的工作区不使用预热会话(预热时无法得知附加目录)。
    /// - Parameters:
    ///   - agentID: 引擎 ID
    ///   - project: 项目
    public func takeWarmSession(agentID: String, project: ProjectEntry) -> SessionModel? {
        guard !project.isMultiRoot, !project.isChatArea, let model = warmPool.take(agentID: agentID, workspace: project.url) else { return nil }
        onWarmSessionTaken?()
        return model
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

    /// 在项目下开始新对话:新开一个会话标签(各自独立的 Agent 会话);
    /// 若当前项目的活动会话标签还是空白的,直接复用它,不再多开一个空标签。
    public func newConversation(in id: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        mode = .workspace
        if let current = sessions[id], current.isPristine,
           let tab = dock.allTabs.first(where: { if case .chat(let p, _) = $0.kind { return p == id && session(forTab: $0) === current } else { return false } }) {
            dock.activate(tab.id)
            syncSelectionFromDock()
            return
        }
        let slot = UUID().uuidString
        let title = project.isChatArea ? String(localized: "新对话") : String(localized: "新对话") + " · " + project.name
        let tab = dock.open(.chat(projectID: id, slot: slot), title: title)
        dock.activate(tab)
        lastSlot[id] = .some(slot)
        ensureSession(project: id, slot: slot)
        closeSubagentTabs(in: id)
        scheduleSave()
    }

    /// 在项目下用指定引擎开始新对话:总是新开标签(已有会话保持原样,切换引擎不影响任何已有会话)。
    /// - Parameters:
    ///   - id: 项目 ID
    ///   - agentID: 承载新对话的引擎
    public func newConversation(in id: String, agentID: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        selectedProjectID = id
        mode = .workspace
        let slot = UUID().uuidString
        let title = project.isChatArea ? String(localized: "新对话") : String(localized: "新对话") + " · " + project.name
        let tab = dock.open(.chat(projectID: id, slot: slot), title: title)
        dock.activate(tab)
        lastSlot[id] = .some(slot)
        ensureSession(project: id, slot: slot, agentID: agentID)
        closeSubagentTabs(in: id)
        scheduleSave()
    }

    /// 分叉会话并在新标签页中打开 (对标 Cursor Fork Chat)
    @discardableResult
    public func forkConversation(from source: SessionModel) -> UUID? {
        guard let projectID = selectedProjectID ?? projects.first?.id,
              let project = projects.first(where: { $0.id == projectID }) else { return nil }
        mode = .workspace
        let slot = UUID().uuidString
        let baseTitle = (source.sessionTitle?.isEmpty == false) ? source.sessionTitle! : project.name
        let tab = dock.open(.chat(projectID: projectID, slot: slot), title: String(localized: "分支") + " · " + baseTitle)
        dock.activate(tab)
        lastSlot[projectID] = .some(slot)
        if let newSession = ensureSession(project: projectID, slot: slot) {
            newSession.cloneHistory(from: source)
            Task {
                await newSession.forkFrom(source: source)
            }
        }
        closeSubagentTabs(in: projectID)
        scheduleSave()
        return tab
    }

    /// 缓存里某个会话的标题(没有时为 nil)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - id: 项目 ID
    func cachedTitle(ofSession sessionId: String, in id: String) -> String? {
        projects.first { $0.id == id }?.sessions.first { $0.sessionId == sessionId }?.title
    }

    /// 缓存里某个会话所属的 Agent(旧数据或未登记为 nil)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - id: 项目 ID
    public func cachedAgentID(ofSession sessionId: String, in id: String) -> String? {
        projects.first { $0.id == id }?.sessions.first { $0.sessionId == sessionId }?.agentId
    }

    /// 在项目下打开历史会话:已经在某个标签里打开的直接切过去;否则新开一个标签承载。
    ///
    /// 会话属于某个 Agent(引擎)。属于其他引擎的会话会用原引擎新开标签承载,
    /// 这样切换引擎后原来的会话依然能恢复,不会因为引擎不认识会话 ID 而打不开。
    /// - Parameters:
    ///   - id: 项目 ID
    ///   - sessionId: 协议会话 ID
    ///   - title: 标题(兜底显示)
    ///   - agentID: 会话所属 Agent;nil 时取缓存里登记的归属
    public func openHistory(project id: String, sessionId: String, title: String?, agentID: String? = nil) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let owner = agentID ?? cachedAgentID(ofSession: sessionId, in: id)
        mode = .workspace
        selectedProjectID = id
        if let (key, _) = conversations.first(where: { $0.key.projectID == id && $0.value.sessionId == sessionId }),
           let tab = dock.tab(for: .chat(projectID: id, slot: key.slot)) {
            dock.activate(tab.id)
            syncSelectionFromDock()
            return
        }
        // 总是新开标签打开历史会话:空白新对话也是真实会话,必须保留在侧栏里,不能被顶替;会话属于别的引擎时用原引擎承载
        let foreignAgent = owner.flatMap { $0 != sessions[id]?.descriptor.id ? $0 : nil }
        var target: SessionModel?
        do {
            let slot = UUID().uuidString
            let tab = dock.open(.chat(projectID: id, slot: slot), title: title ?? project.name)
            dock.activate(tab)
            lastSlot[id] = .some(slot)
            // 新标签走「恢复模式」:连接后直接 session/load,不先建空会话,侧栏也不会闪出「新对话」
            let pending = SessionSummary(sessionId: sessionId, cwd: id, title: title ?? cachedTitle(ofSession: sessionId, in: id))
            target = ensureSession(project: id, slot: slot, agentID: foreignAgent, restore: pending)
        }
        guard let model = target else { return }
        // 恢复模式已接管:无需再走「等连接就绪后打开」
        if model.sessionId == sessionId, model.isReplaying || model.phase != .ready {
            closeSubagentTabs(in: id)
            scheduleSave()
            return
        }
        let summary = model.history.first { $0.sessionId == sessionId } ?? SessionSummary(sessionId: sessionId, cwd: id, title: title)
        if model.phase == .ready {
            model.openSession(summary)
        } else {
            // 新会话还在连接:连上后再打开历史会话
            pendingOpen[model.uid] = summary
            Task { [weak self, weak model] in
                for _ in 0..<150 {
                    guard let model else { return }
                    if model.phase == .ready { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self, let model, let pending = self.pendingOpen.removeValue(forKey: model.uid) else { return }
                model.openSession(pending)
            }
        }
        closeSubagentTabs(in: id)
        scheduleSave()
    }

    /// 等待连接就绪后再打开的历史会话(按会话 uid)。
    @ObservationIgnored private var pendingOpen: [String: SessionSummary] = [:]

    /// 会话模型创建(幂等):确保某个会话槽位有对应的 SessionModel。
    /// - Parameters:
    ///   - id: 项目 ID
    ///   - slot: 会话槽位(nil 为项目主会话)
    ///   - agentID: 指定承载的 Agent;nil 或工厂不认识时用默认 Agent
    @discardableResult
    public func ensureSession(project id: String, slot: String?, agentID: String? = nil, restore: SessionSummary? = nil) -> SessionModel? {
        let key = ConversationKey(projectID: id, slot: slot)
        if let existing = conversations[key] { return existing }
        guard let project = projects.first(where: { $0.id == id }) else { return nil }
        // 启动恢复:这个标签退出前承载着一个会话,在原标签里恢复同一个会话(原引擎承载)
        var agentID = agentID
        var restore = restore
        if restore == nil, agentID == nil, let record = pendingRestores.removeValue(forKey: key), !isSessionDeleted(record.sessionId, in: id) {
            restore = SessionSummary(sessionId: record.sessionId, cwd: id, title: record.title)
            if let owner = record.agentId, makeAgentSession != nil { agentID = owner }
        }
        // 指定引擎:先认领待命会话;未指定时认领默认引擎的待命会话(新对话/打开历史不再等启动与握手)
        let model: SessionModel
        if let agentID {
            model = takeWarmSession(agentID: agentID, project: project) ?? makeAgentSession?(project.url, agentID) ?? makeSession(project.url)
        } else if let defaultID = defaultAgentID?(), let warm = takeWarmSession(agentID: defaultID, project: project) {
            model = warm
        } else {
            model = makeSession(project.url)
        }
        if project.isChatArea { model.extraSystemPrompt = Self.chatAreaPrompt }
        model.additionalDirectories = project.extraFolders
        wire(model, project: id)
        conversations[key] = model
        // 已连好的待命会话 phase 不是 idle,prepareRestore 会自动忽略,由调用方走常规 openSession
        if let restore { model.prepareRestore(restore) }
        if autoConnect { model.connect() }
        // 认领的待命会话可能已就绪:预热期间尚未接线,补刷一次历史列表让缓存同步
        if model.phase == .ready { model.refreshHistory() }
        return model
    }

    /// 确保项目当前会话存在(兼容旧调用)。
    @discardableResult
    public func ensureSession(for id: String) -> SessionModel? {
        ensureSession(project: id, slot: preferredSlot(for: id))
    }

    /// 给会话挂接历史缓存与跟随回调。
    private func wire(_ model: SessionModel, project id: String) {
        model.onHistoryChanged = { [weak self, weak model] history in
            self?.cacheHistory(history, agentID: model?.descriptor.id, for: id)
        }
        model.onAgentEdit = { [weak self] edit in self?.followAgentEdit(edit, project: id) }
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
        let slot = preferredSlot(for: id)
        let key = ConversationKey(projectID: id, slot: slot)
        if let old = conversations[key], let sessionId = old.sessionId, !old.isPristine {
            // 切换引擎不丢会话:旧引擎的会话记入缓存,侧栏里仍可见,点击时切回原引擎打开
            rememberSession(sessionId, title: old.sessionTitle, agentID: old.descriptor.id, for: id)
        }
        conversations[key]?.shutdown()
        if let project = projects.first(where: { $0.id == id }) { model.additionalDirectories = project.extraFolders }
        wire(model, project: id)
        conversations[key] = model
        lastSlot[id] = .some(slot)
        if autoConnect { model.connect() }
        // 认领的预热会话可能已就绪:补刷一次历史列表(预热期间尚未接线,回调没有生效)
        if model.phase == .ready { model.refreshHistory() }
    }

    /// 缓存历史会话摘要(只增不减:引擎列表没返回的条目照常保留,仅用户删除会写墓碑);
    /// 为每条会话保留真实创建时间作为恒定排序键。
    ///
    /// 会话按 Agent 记录归属:某个 Agent 的列表刷新**不会冲掉任何已有会话**
    /// (切换引擎后,原引擎的会话仍在侧栏,点击时会切回对应引擎打开)。
    /// - Parameters:
    ///   - history: 当前 Agent 返回的会话列表
    ///   - agentID: 该列表所属的 Agent;nil 表示不区分(旧调用方式,整体替换)
    ///   - id: 项目 ID
    ///   - now: 当前时间(测试可注入)
    func cacheHistory(_ history: [SessionSummary], agentID: String? = nil, for id: String, now: Date = Date()) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let existing = projects[index].sessions
        let tombstones = Set(projects[index].deletedSessions)
        let previous = Dictionary(existing.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = history.filter { !tombstones.contains($0.sessionId) }.prefix(Self.cachedSessionLimit).enumerated().map { (offset, item) -> CachedSession in
            let existingCreated = previous[item.sessionId]?.createdAt ?? previous[item.sessionId]?.firstSeenAt
            let createdAt: String
            if let existingCreated, !existingCreated.isEmpty {
                createdAt = existingCreated
            } else if let physical = SessionTimeResolver.resolvePhysicalCreationDate(sessionId: item.sessionId, projectPath: id, agentID: agentID) {
                createdAt = physical.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            } else if let updated = item.updatedAt, !updated.isEmpty {
                createdAt = updated
            } else {
                let simulated = now.addingTimeInterval(-Double(offset) * 1.0)
                createdAt = simulated.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            }
            // 沿用已登记的所属引擎:避免旧缓存里的归属被无归属的刷新抹掉
            return CachedSession(
                sessionId: item.sessionId, title: item.title, updatedAt: item.updatedAt,
                createdAt: createdAt, firstSeenAt: createdAt, agentId: agentID ?? previous[item.sessionId]?.agentId
            )
        }
        // 本次列表没有返回的条目一律保留:引擎列表可能分页、瞬时变短或失败,
        // 侧栏必须稳定;只有用户主动删除(墓碑)才会让会话消失。
        let freshIDs = Set(fresh.map(\.sessionId))
        let kept = existing.filter { !freshIDs.contains($0.sessionId) && !tombstones.contains($0.sessionId) }
        let cached = Array((fresh + kept).prefix(Self.cachedSessionRetention))
        guard projects[index].sessions != cached else { return }
        projects[index].sessions = cached
        scheduleSave()
    }

    /// 每次刷新最多采纳的会话条数。
    static let cachedSessionLimit = 100
    /// 单个项目侧栏缓存保留的会话总数上限。
    static let cachedSessionRetention = 400

    /// 从侧栏与缓存中彻底移除一个会话:清理缓存/置顶/归档、写入墓碑、关闭正在显示它的标签。
    /// 引擎侧的删除由调用方负责(需要对应引擎的连接);这里只处理客户端状态。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - id: 项目 ID
    /// - Returns: 是否找到了项目
    @discardableResult
    public func forgetSession(_ sessionId: String, in id: String) -> Bool {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        projects[index].sessions.removeAll { $0.sessionId == sessionId }
        projects[index].pinnedSessions.removeAll { $0 == sessionId }
        projects[index].archivedSessions.removeAll { $0 == sessionId }
        if !projects[index].deletedSessions.contains(sessionId) { projects[index].deletedSessions.append(sessionId) }
        // 关闭正在显示该会话的标签
        let slots: [String?] = conversations.filter { $0.key.projectID == id && $0.value.sessionId == sessionId }.map(\.key.slot)
        if !slots.isEmpty {
            dock.closeTabs { tab in
                if case .chat(let projectID, let slot) = tab.kind { return projectID == id && slots.contains(slot) }
                return false
            }
            if let last = lastSlot[id], slots.contains(last) { lastSlot[id] = nil }
            syncSelectionFromDock()
            // 该项目一个会话标签都不剩时补一个空白会话,保证主区域有内容可显示
            let hasChatTab = dock.allTabs.contains { if case .chat(let projectID, _) = $0.kind { return projectID == id } else { return false } }
            if selectedProjectID == id, !hasChatTab { select(project: id) }
        }
        log.info("删除会话", ["project": id, "session": String(sessionId.prefix(8))])
        scheduleSave()
        return true
    }

    /// 会话是否已被用户删除(墓碑)。
    public func isSessionDeleted(_ sessionId: String, in id: String) -> Bool {
        projects.first { $0.id == id }?.deletedSessions.contains(sessionId) ?? false
    }

    /// 记住某个会话(切换引擎或关闭前调用):列表刷新可能还没覆盖到它,这里直接写入缓存,保证不丢。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - title: 标题
    ///   - agentID: 所属 Agent
    ///   - id: 项目 ID
    func rememberSession(_ sessionId: String, title: String?, agentID: String, for id: String, now: Date = Date()) {
        guard !sessionId.isEmpty, let index = projects.firstIndex(where: { $0.id == id }),
              !projects[index].deletedSessions.contains(sessionId) else { return }
        let nowText = now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        if let at = projects[index].sessions.firstIndex(where: { $0.sessionId == sessionId }) {
            var item = projects[index].sessions[at]
            if item.agentId == nil { item.agentId = agentID }
            if let title, !title.isEmpty { item.title = title }
            if item.createdAt == nil { item.createdAt = item.firstSeenAt ?? nowText }
            projects[index].sessions[at] = item
        } else {
            let physical = SessionTimeResolver.resolvePhysicalCreationDate(sessionId: sessionId, projectPath: id, agentID: agentID)
            let createdText = physical?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) ?? nowText
            projects[index].sessions.append(CachedSession(sessionId: sessionId, title: title, updatedAt: nowText, createdAt: createdText, firstSeenAt: createdText, agentId: agentID))
        }
        scheduleSave()
    }

    /// 自愈修复会话创建时间:对旧数据中缺失创建时间或因批量赋值共享相同时间戳的会话,从文件系统解析真实物理创建时间纠偏。
    func healSessionCreationDates() {
        var changed = false
        for pIndex in projects.indices {
            let proj = projects[pIndex]
            var sessions = proj.sessions
            var counts: [String: Int] = [:]
            for s in sessions {
                if let k = s.createdAt ?? s.firstSeenAt { counts[k, default: 0] += 1 }
            }
            for sIndex in sessions.indices {
                var s = sessions[sIndex]
                let currentKey = s.createdAt ?? s.firstSeenAt
                let isDuplicated = currentKey.map { (counts[$0] ?? 0) > 1 } ?? true
                let needsHeal = s.createdAt == nil || isDuplicated
                if needsHeal, let physical = SessionTimeResolver.resolvePhysicalCreationDate(sessionId: s.sessionId, projectPath: proj.id, agentID: s.agentId) {
                    let fixed = physical.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                    if s.createdAt != fixed {
                        s.createdAt = fixed
                        s.firstSeenAt = fixed
                        sessions[sIndex] = s
                        changed = true
                    }
                }
            }
            if proj.sessions != sessions {
                projects[pIndex].sessions = sessions
            }
        }
        if changed { scheduleSave() }
    }

    /// 关闭所有会话(应用退出)。
    public func shutdownAll() {
        // 先落盘再关闭会话:shutdown 会清空 sessionId,晚存就丢了「标签 → 会话」的恢复记录
        saveNow()
        for model in conversations.values { model.shutdown() }
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
        layout.outputWidth = PanelMetrics.terminalDefault
        layout.bottomHeight = 240
    }

    /// 应用新的摆放配置;终端/输出位置变化时迁移其显示状态。
    private func applyPlacement(_ next: PanelPlacement) {
        let terminalWasShown = isTerminalShown
        let outputWasShown = isOutputShown
        let oldTerminal = layout.placement.terminal
        let oldOutput = layout.placement.output
        guard next != layout.placement else { return }
        layout.placement = next
        if next.terminal != oldTerminal {
            // 清理旧位置:编辑区标签关闭(不进入「最近关闭」),底部/侧栏显隐复位
            if oldTerminal == .editor { for tab in residentTerminalTabs { dock.close(tab.id) } }
            if oldTerminal == .bottom, layout.bottomPane == .terminal { layout.bottomPane = .output; layout.bottomVisible = false }
            if oldTerminal.isSide { layout.terminalVisible = false }
        }
        if next.output != oldOutput {
            if oldOutput == .editor { for tab in outputTabs { dock.close(tab.id) } }
            if oldOutput == .bottom, layout.bottomPane == .output { layout.bottomPane = .terminal; layout.bottomVisible = layout.bottomVisible && next.terminal == .bottom }
            if oldOutput.isSide { layout.outputVisible = false }
        }
        layout.clamp()
        if next.terminal != oldTerminal, terminalWasShown { showTerminal() }
        if next.output != oldOutput, outputWasShown { showOutput() }
        if next.terminal != oldTerminal || next.output != oldOutput { syncSelectionFromDock() }
        layout.clamp()
    }

    // MARK: 自动化页

    /// 自动化页在编辑区里的标签标识(预览类标签)。
    public nonisolated static let automationTabID = "oma-automation"

    /// 打开(或切到)自动化页标签。
    @discardableResult
    public func openAutomation() -> UUID {
        mode = .workspace
        let tab = dock.open(.preview(id: Self.automationTabID), title: String(localized: "自动化"))
        dock.activate(tab)
        syncSelectionFromDock()
        return tab
    }

    // MARK: 自定义页

    /// 自定义页(MCP / 技能 / 子 Agent / Hooks / 插件 / 记忆)在编辑区里的标签标识(预览类标签)。
    public nonisolated static let customizeTabID = "oma-customize"

    /// 自定义页当前的类型筛选(`all/plugins/skills/subagents/rules/mcp/hooks`)。
    public var customizeFilter = "all"

    /// 打开(或切到)自定义页标签。
    /// - Parameter filter: 预选的类型筛选;nil 保持当前
    @discardableResult
    public func openCustomize(filter: String? = nil) -> UUID {
        if let filter { customizeFilter = filter }
        mode = .workspace
        let tab = dock.open(.preview(id: Self.customizeTabID), title: String(localized: "自定义"))
        dock.activate(tab)
        syncSelectionFromDock()
        return tab
    }

    // MARK: Canvas

    /// 画布标签的标识前缀(预览类标签,后缀为画布 id)。
    public nonisolated static let canvasTabPrefix = "oma-canvas:"

    /// 从预览标签标识里取画布 id;不是画布标签返回 nil。
    /// - Parameter tabID: 预览标签标识
    public nonisolated static func canvasID(fromTab tabID: String) -> String? {
        tabID.hasPrefix(canvasTabPrefix) ? String(tabID.dropFirst(canvasTabPrefix.count)) : nil
    }

    /// 打开(或切到)画布标签。
    /// - Parameters:
    ///   - id: 画布 id
    ///   - title: 标签标题
    @discardableResult
    public func openCanvas(id: String, title: String) -> UUID {
        mode = .workspace
        let tab = dock.open(.preview(id: Self.canvasTabPrefix + id), title: title)
        dock.activate(tab)
        syncSelectionFromDock()
        return tab
    }

    // MARK: 计划标签

    /// 计划标签的标识前缀(预览类标签,后缀为计划文件的绝对路径)。
    public nonisolated static let planTabPrefix = "oma-plan:"

    /// 从预览标签标识里取计划文件路径;不是计划标签返回 nil。
    /// - Parameter tabID: 预览标签标识
    public nonisolated static func planPath(fromTab tabID: String) -> String? {
        tabID.hasPrefix(planTabPrefix) ? String(tabID.dropFirst(planTabPrefix.count)) : nil
    }

    /// 打开(或切到)计划标签。
    /// - Parameters:
    ///   - path: 计划文件(`*.plan.md`)的绝对路径
    ///   - title: 标签标题
    @discardableResult
    public func openPlan(path: String, title: String) -> UUID {
        mode = .workspace
        let tab = dock.open(.preview(id: Self.planTabPrefix + path), title: title)
        dock.activate(tab)
        syncSelectionFromDock()
        return tab
    }

    // MARK: 浏览器标签

    /// 浏览器标签的标识前缀(预览类标签,后缀为浏览器标签 id)。
    public nonisolated static let browserTabPrefix = "oma-browser:"

    /// 从预览标签标识里取浏览器标签 id;不是浏览器标签返回 nil。
    /// - Parameter tabID: 预览标签标识
    public nonisolated static func browserID(fromTab tabID: String) -> String? {
        tabID.hasPrefix(browserTabPrefix) ? String(tabID.dropFirst(browserTabPrefix.count)) : nil
    }

    /// 打开(或切到)浏览器标签。
    /// - Parameters:
    ///   - id: 浏览器标签 id
    ///   - title: 标签标题
    ///   - activate: 是否切到该标签(Agent 在后台打开页面时为 false,不抢焦点)
    @discardableResult
    public func openBrowser(id: String, title: String, activate: Bool = true) -> UUID {
        mode = .workspace
        let tab = dock.open(.preview(id: Self.browserTabPrefix + id), title: title)
        if activate {
            dock.activate(tab)
            syncSelectionFromDock()
        }
        return tab
    }

    /// 更新浏览器标签标题(页面标题变化时)。
    /// - Parameters:
    ///   - id: 浏览器标签 id
    ///   - title: 新标题
    public func setBrowserTitle(id: String, title: String) {
        guard let tab = dock.allTabs.first(where: { $0.kind == .preview(id: Self.browserTabPrefix + id) }) else { return }
        dock.setTitle(title, for: tab.id)
    }

    /// 浏览器标签当前是否仍在编辑区里。
    /// - Parameter id: 浏览器标签 id
    public func isBrowserOpen(id: String) -> Bool {
        dock.allTabs.contains { $0.kind == .preview(id: Self.browserTabPrefix + id) }
    }

    // MARK: 输出面板

    /// 输出面板在编辑区里的标签标识(放在编辑区时作为预览类标签)。
    public nonisolated static let outputTabID = "oma-output"

    /// 编辑区中的输出标签。
    private var outputTabs: [WorkbenchTab] {
        dock.allTabs.filter { $0.kind == .preview(id: Self.outputTabID) }
    }

    /// 输出面板当前是否显示在界面上。
    public var isOutputShown: Bool {
        switch layout.placement.output {
        case .bottom: return layout.bottomVisible && layout.bottomPane == .output
        case .left, .right: return layout.outputVisible
        case .editor: return !outputTabs.isEmpty
        }
    }

    /// 显示输出面板(按当前摆放位置)。
    public func showOutput() {
        switch layout.placement.output {
        case .bottom: showBottom(.output)
        case .left, .right: layout.outputVisible = true
        case .editor:
            let tab = dock.open(.preview(id: Self.outputTabID), title: String(localized: "输出"))
            mode = .workspace
            dock.activate(tab)
            syncSelectionFromDock()
        }
    }

    /// 隐藏输出面板。
    public func hideOutput() {
        switch layout.placement.output {
        case .bottom: if layout.bottomPane == .output { layout.bottomVisible = false }
        case .left, .right: layout.outputVisible = false
        case .editor:
            for tab in outputTabs { dock.close(tab.id) }
            syncSelectionFromDock()
        }
    }

    /// 切换输出面板显隐。
    public func toggleOutput() {
        if isOutputShown { hideOutput() } else { showOutput() }
    }

    /// 把输出面板移动到新位置。
    /// - Parameter target: 目标位置
    public func setOutputPlacement(_ target: TerminalPlacement) {
        var next = layout.placement
        next.output = target
        applyPlacement(next)
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

    /// 当前仍有内容的会话标签记录(已创建会话的取实时状态;尚未显示的取启动时读到的记录),退出后用于恢复。
    private func chatSlotRecords() -> [ChatSlotRecord] {
        var result: [ConversationKey: ChatSlotRecord] = [:]
        let openTabs = Set(dock.allTabs.compactMap { tab -> ConversationKey? in
            if case .chat(let projectID, let slot) = tab.kind { return ConversationKey(projectID: projectID, slot: slot) }
            return nil
        })
        for (key, record) in pendingRestores where openTabs.contains(key) { result[key] = record }
        for (key, model) in conversations where openTabs.contains(key) {
            guard let sessionId = model.sessionId, !model.isPristine || model.isReplaying else { continue }
            result[key] = ChatSlotRecord(projectID: key.projectID, slot: key.slot, sessionId: sessionId, agentId: model.descriptor.id, title: model.sessionTitle)
        }
        return result.values.sorted { ($0.projectID, $0.slot ?? "") < ($1.projectID, $1.slot ?? "") }
    }

    /// 立即写盘。
    public func saveNow() {
        saveTask?.cancel()
        var state = WorkbenchState()
        state.layout = layout
        state.projects = projects
        state.selectedProjectID = selectedProjectID
        state.dock = dock
        state.chatSlots = chatSlotRecords()
        let span = Log.perf.span("保存工作台状态", warnMs: 30, quiet: true, ["projects": "\(projects.count)"])
        defer { span.end() }
        do { try store.save(state) } catch { log.error("保存工作台状态失败", error: error, ["file": store.fileURL.path]) }
    }
}
