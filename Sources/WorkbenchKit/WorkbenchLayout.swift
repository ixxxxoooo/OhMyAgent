// @author ixxxxoooo
// 工作台布局与持久化模型:三栏 + 底部面板的显隐/尺寸/当前视图,以及项目列表。

import Foundation

/// 主窗口显示的内容。
public enum WorkbenchMode: Equatable, Sendable {
    /// 工作台(左栏 + 中栏 + 右栏)
    case workspace
    /// 设置整页(并入主窗口,通过「返回」回到工作台)
    case settings
}

/// 左栏视图。
public enum LeftPane: String, Codable, CaseIterable, Sendable {
    case sessions, files, git, search

    /// 已实现的视图(随里程碑逐步开放)。
    public static var available: [LeftPane] { [.sessions] }
}

/// 右栏视图。
public enum RightPane: String, Codable, CaseIterable, Sendable {
    case changes, plan, outline, problems, files, search, git, terminal

    /// 右栏分段顺序:文件、搜索、Git。
    /// 旧版本的 `changes`(本轮改动)并入 Git 页,`plan` 由输入区上方的待办条承担,`terminal` 与底部面板/终端标签重复,故不再提供。
    public static var available: [RightPane] { [.files, .search, .git] }
}

/// 底部面板视图。
public enum BottomPane: String, Codable, CaseIterable, Sendable {
    case terminal, output, problems

    public static var available: [BottomPane] { [.terminal, .output] }
}

/// 工作台布局。
public struct WorkbenchLayout: Codable, Equatable, Sendable {
    public var leftVisible = true
    public var rightVisible = false
    public var bottomVisible = false
    public var leftWidth: Double = PanelMetrics.leftDefault
    public var rightWidth: Double = PanelMetrics.rightDefault
    public var bottomHeight: Double = 240
    public var leftPane: LeftPane = .sessions
    public var rightPane: RightPane = .files
    public var bottomPane: BottomPane = .output
    /// 各面板的摆放位置(终端位置、项目栏与工具栏所在侧)
    public var placement = PanelPlacement()
    /// 终端侧栏是否可见(终端放到左/右侧时有效)
    public var terminalVisible = false
    /// 终端侧栏宽度
    public var terminalWidth: Double = PanelMetrics.terminalDefault
    /// 输出侧栏是否可见(输出放到左/右侧时有效)
    public var outputVisible = false
    /// 输出侧栏宽度
    public var outputWidth: Double = PanelMetrics.terminalDefault

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case leftVisible, rightVisible, bottomVisible, leftWidth, rightWidth, bottomHeight
        case leftPane, rightPane, bottomPane, placement, terminalVisible, terminalWidth, outputVisible, outputWidth
    }

    /// 容错解码:新增字段缺失或取值未知时使用默认值,旧版本状态文件可继续读取。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leftVisible = try c.decodeIfPresent(Bool.self, forKey: .leftVisible) ?? true
        rightVisible = try c.decodeIfPresent(Bool.self, forKey: .rightVisible) ?? false
        bottomVisible = try c.decodeIfPresent(Bool.self, forKey: .bottomVisible) ?? false
        leftWidth = try c.decodeIfPresent(Double.self, forKey: .leftWidth) ?? PanelMetrics.leftDefault
        rightWidth = try c.decodeIfPresent(Double.self, forKey: .rightWidth) ?? PanelMetrics.rightDefault
        bottomHeight = try c.decodeIfPresent(Double.self, forKey: .bottomHeight) ?? 240
        leftPane = (try? c.decodeIfPresent(LeftPane.self, forKey: .leftPane)) ?? .sessions
        rightPane = (try? c.decodeIfPresent(RightPane.self, forKey: .rightPane)) ?? .files
        bottomPane = (try? c.decodeIfPresent(BottomPane.self, forKey: .bottomPane)) ?? .output
        placement = (try? c.decodeIfPresent(PanelPlacement.self, forKey: .placement)) ?? PanelPlacement()
        terminalVisible = try c.decodeIfPresent(Bool.self, forKey: .terminalVisible) ?? false
        terminalWidth = try c.decodeIfPresent(Double.self, forKey: .terminalWidth) ?? PanelMetrics.terminalDefault
        outputVisible = try c.decodeIfPresent(Bool.self, forKey: .outputVisible) ?? false
        outputWidth = try c.decodeIfPresent(Double.self, forKey: .outputWidth) ?? PanelMetrics.terminalDefault
    }

    /// 限制各尺寸在合理范围内(防止损坏的状态文件导致不可见的面板),并校正与摆放位置相关的状态。
    public mutating func clamp() {
        leftWidth = min(max(leftWidth, PanelMetrics.leftRange.lowerBound), PanelMetrics.leftRange.upperBound)
        rightWidth = min(max(rightWidth, PanelMetrics.rightRange.lowerBound), PanelMetrics.rightRange.upperBound)
        terminalWidth = min(max(terminalWidth, PanelMetrics.terminalRange.lowerBound), PanelMetrics.terminalRange.upperBound)
        outputWidth = min(max(outputWidth, PanelMetrics.terminalRange.lowerBound), PanelMetrics.terminalRange.upperBound)
        bottomHeight = min(max(bottomHeight, 120), 600)
        if !LeftPane.available.contains(leftPane) { leftPane = .sessions }
        if !RightPane.available.contains(rightPane) { rightPane = .files }
        if !BottomPane.available.contains(bottomPane) { bottomPane = .output }
        // 底部面板只显示摆放在底部的面板;没有任何面板在底部时,底部面板不可见
        if placement.terminal != .bottom && bottomPane == .terminal { bottomPane = .output }
        if placement.output != .bottom && bottomPane == .output && placement.terminal == .bottom { bottomPane = .terminal }
        if placement.terminal != .bottom && placement.output != .bottom { bottomVisible = false }
        if !placement.terminal.isSide { terminalVisible = false }
        if !placement.output.isSide { outputVisible = false }
    }
}

/// 项目内缓存的历史会话(使项目树无需启动 Agent 即可展示)。
public struct CachedSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var title: String?
    public var updatedAt: String?
    /// 会话物理或逻辑创建时间(ISO8601):一旦确立永不改变,作为侧栏按创建时间倒序排列的恒定排序键。
    public var createdAt: String?
    /// 首次被侧栏看到的时间(ISO8601):旧版本字段,兼容保留。
    public var firstSeenAt: String?
    /// 该会话属于哪个 Agent(引擎)。会话由 Agent 在服务端保存,别的引擎打不开,
    /// 所以切换引擎时按此标记分开保留;旧数据没有该字段(nil 视为当前引擎)。
    public var agentId: String?

    public init(sessionId: String, title: String?, updatedAt: String?, createdAt: String? = nil, firstSeenAt: String? = nil, agentId: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt ?? firstSeenAt
        self.firstSeenAt = firstSeenAt ?? createdAt
        self.agentId = agentId
    }

    /// 侧栏稳定排序键:优先真实创建时间,缺失时回退到首次出现时间与更新时间。
    public var stableKey: Date {
        WorkbenchModel.parseDate(createdAt) ?? WorkbenchModel.parseDate(firstSeenAt) ?? WorkbenchModel.parseDate(updatedAt) ?? .distantPast
    }
}

/// 项目条目(工作台左栏的一级节点)。
public struct ProjectEntry: Codable, Equatable, Sendable, Identifiable {
    /// 标准化后的目录路径
    public var id: String
    public var name: String
    public var addedAt: Date
    public var lastOpenedAt: Date
    public var pinned = false
    public var collapsed = false
    public var sessions: [CachedSession] = []
    /// 已置顶的会话 ID(按置顶先后排列)
    public var pinnedSessions: [String] = []
    /// 已归档的会话 ID(不在列表中显示,可在「已归档」中恢复)
    public var archivedSessions: [String] = []
    /// 是否为「会话区」:不绑定任何项目的通用对话(ChatGPT 式问答),工作目录是应用支持目录下的空目录。
    /// 它复用项目的会话机制(历史、置顶、归档、标签),但不出现在项目列表里。
    public var isChatArea = false
    /// 自定义侧栏图标(nil 为默认文件夹图标)
    public var icon: ProjectIcon?
    /// 工作区里额外的文件夹(绝对路径,不含主目录 `id`);Agent、搜索、文件树与 Git 面板会覆盖它们
    public var extraFolders: [String] = []

    public var url: URL { URL(fileURLWithPath: id) }

    public init(url: URL, now: Date = Date()) {
        id = url.standardizedFileURL.path
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        addedAt = now
        lastOpenedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, addedAt, lastOpenedAt, pinned, collapsed, sessions, pinnedSessions, archivedSessions, isChatArea, icon, extraFolders
    }

    /// 容错解码:新增字段缺失时使用默认值,旧版本状态文件可继续读取。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        sessions = try c.decodeIfPresent([CachedSession].self, forKey: .sessions) ?? []
        pinnedSessions = try c.decodeIfPresent([String].self, forKey: .pinnedSessions) ?? []
        archivedSessions = try c.decodeIfPresent([String].self, forKey: .archivedSessions) ?? []
        isChatArea = try c.decodeIfPresent(Bool.self, forKey: .isChatArea) ?? false
        icon = try c.decodeIfPresent(ProjectIcon.self, forKey: .icon)
        extraFolders = try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? []
    }
}

/// 持久化的工作台状态。
public struct WorkbenchState: Codable, Equatable, Sendable {
    public var layout = WorkbenchLayout()
    public var projects: [ProjectEntry] = []
    public var selectedProjectID: String?
    /// 停靠布局(旧版本状态文件没有该字段)
    public var dock: DockLayout?

    public init() {}
}

/// 状态文件存取(JSON,原子写入;读取失败回退默认值并记录日志由调用方处理)。
public struct WorkbenchStore: Sendable {
    public let fileURL: URL

    /// - Parameter fileURL: 状态文件;默认 `~/Library/Application Support/OhMyAgent/workbench.json`
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OhMyAgent", isDirectory: true)
            .appendingPathComponent("workbench.json")
    }

    /// 读取状态;文件不存在或损坏时返回 nil。
    public func load() -> WorkbenchState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(WorkbenchState.self, from: data) else { return nil }
        state.layout.clamp()
        return state
    }

    /// 写入状态。
    public func save(_ state: WorkbenchState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
