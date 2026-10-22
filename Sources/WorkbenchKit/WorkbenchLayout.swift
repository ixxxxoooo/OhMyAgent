// @author ixxxxoooo
// 工作台布局与持久化模型:三栏 + 底部面板的显隐/尺寸/当前视图,以及项目列表。

import Foundation
import OMLog

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

/// 右栏视图(文件 / 搜索 / Git)。它们是右栏停靠区里的工具面板标签(`oma-tools:<rawValue>`)。
public enum RightPane: String, Codable, CaseIterable, Sendable {
    case changes, plan, outline, problems, files, search, git, terminal

    /// 可用的工具面板:文件、搜索、Git。
    /// 旧版本的 `changes`(本轮改动)并入 Git 页,`plan` 由输入区上方的待办条承担,`terminal` 现为独立的终端标签,故不再提供。
    public static var available: [RightPane] { [.files, .search, .git] }
}

/// 旧版本布局(底部面板 / 终端侧栏 / 工具栏单视图)迁移到右栏停靠区所需的信息;只在读取旧状态文件时产生,启动时由工作台消费。
public struct LegacyPanelMigration: Equatable, Sendable {
    /// 旧布局里终端是否可见(且不在编辑区)
    public var showTerminal = false
    /// 旧布局里输出是否可见(且不在编辑区)
    public var showOutput = false
    /// 旧布局里右栏正显示的工具视图(右栏可见时)
    public var rightPane: RightPane?

    public init(showTerminal: Bool = false, showOutput: Bool = false, rightPane: RightPane? = nil) {
        self.showTerminal = showTerminal
        self.showOutput = showOutput
        self.rightPane = rightPane
    }

    /// 是否没有任何需要迁移的内容。
    public var isEmpty: Bool { !showTerminal && !showOutput && rightPane == nil }
}

/// 工作台布局。
public struct WorkbenchLayout: Codable, Equatable, Sendable {
    public var leftVisible = true
    public var rightVisible = false
    public var leftWidth: Double = PanelMetrics.leftDefault
    public var rightWidth: Double = PanelMetrics.rightDefault
    public var leftPane: LeftPane = .sessions
    /// 各面板的摆放位置(项目栏与右栏所在侧)
    public var placement = PanelPlacement()
    /// 文件/Plan 点击时的默认打开位置(右栏或中栏编辑区;`.auto` 视为右栏)
    public var fileOpenTarget: OpenTarget = .right
    /// 终端面板内右侧终端列表的宽度(≥2 个终端时出现)
    public var terminalListWidth: Double = PanelMetrics.terminalListDefault
    /// 终端列表是否被用户手动折叠
    public var terminalListCollapsed = false
    /// Files 工作区右侧资源管理器的宽度
    public var filesTreeWidth: Double = PanelMetrics.filesTreeDefault
    /// Files 工作区右侧资源管理器是否收起(默认收起)
    public var filesTreeCollapsed = true
    /// 旧版本布局迁移信息(不持久化;读取旧状态文件时产生,由工作台启动时消费)
    public var legacyMigration: LegacyPanelMigration?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case leftVisible, rightVisible, leftWidth, rightWidth
        case leftPane, placement, fileOpenTarget, terminalListWidth, terminalListCollapsed, filesTreeWidth, filesTreeCollapsed
    }

    /// 旧版本才有的键,只读取用于迁移。
    private enum LegacyKeys: String, CodingKey {
        case bottomVisible, bottomPane, rightPane, terminalVisible, outputVisible, placement
    }

    /// 旧版 `placement` 里终端/输出的摆放(只读 `editor` 判断)。
    private struct LegacyPlacement: Decodable {
        var terminal: String?
        var output: String?
    }

    /// 容错解码:新增字段缺失或取值未知时使用默认值,旧版本状态文件可继续读取(并产生迁移信息)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leftVisible = try c.decodeIfPresent(Bool.self, forKey: .leftVisible) ?? true
        rightVisible = try c.decodeIfPresent(Bool.self, forKey: .rightVisible) ?? false
        leftWidth = try c.decodeIfPresent(Double.self, forKey: .leftWidth) ?? PanelMetrics.leftDefault
        rightWidth = try c.decodeIfPresent(Double.self, forKey: .rightWidth) ?? PanelMetrics.rightDefault
        leftPane = (try? c.decodeIfPresent(LeftPane.self, forKey: .leftPane)) ?? .sessions
        placement = (try? c.decodeIfPresent(PanelPlacement.self, forKey: .placement)) ?? PanelPlacement()
        fileOpenTarget = (try? c.decodeIfPresent(OpenTarget.self, forKey: .fileOpenTarget)) ?? .right
        terminalListWidth = try c.decodeIfPresent(Double.self, forKey: .terminalListWidth) ?? PanelMetrics.terminalListDefault
        terminalListCollapsed = try c.decodeIfPresent(Bool.self, forKey: .terminalListCollapsed) ?? false
        filesTreeWidth = try c.decodeIfPresent(Double.self, forKey: .filesTreeWidth) ?? PanelMetrics.filesTreeDefault
        filesTreeCollapsed = try c.decodeIfPresent(Bool.self, forKey: .filesTreeCollapsed) ?? true
        // 迁移旧布局:底部/侧栏里可见的终端与输出、右栏正显示的工具视图,都变成右栏停靠区里的标签
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self) {
            let old = (try? legacy.decodeIfPresent(LegacyPlacement.self, forKey: .placement)) ?? nil
            let terminalPlace = old?.terminal ?? "bottom", outputPlace = old?.output ?? "bottom"
            let bottomVisible = (try? legacy.decodeIfPresent(Bool.self, forKey: .bottomVisible)) ?? false
            let bottomPane = (try? legacy.decodeIfPresent(String.self, forKey: .bottomPane)) ?? "output"
            let terminalVisible = (try? legacy.decodeIfPresent(Bool.self, forKey: .terminalVisible)) ?? false
            let outputVisible = (try? legacy.decodeIfPresent(Bool.self, forKey: .outputVisible)) ?? false
            var migration = LegacyPanelMigration()
            if terminalPlace == "bottom" { migration.showTerminal = bottomVisible && bottomPane == "terminal" }
            else if terminalPlace != "editor" { migration.showTerminal = terminalVisible }
            if outputPlace == "bottom" { migration.showOutput = bottomVisible && bottomPane == "output" }
            else if outputPlace != "editor" { migration.showOutput = outputVisible }
            if rightVisible, let raw = try? legacy.decodeIfPresent(String.self, forKey: .rightPane), let pane = RightPane(rawValue: raw), RightPane.available.contains(pane) {
                migration.rightPane = pane
            }
            legacyMigration = migration.isEmpty ? nil : migration
        }
    }

    /// 限制各尺寸在合理范围内(防止损坏的状态文件导致不可见的面板)。
    public mutating func clamp() {
        leftWidth = min(max(leftWidth, PanelMetrics.leftRange.lowerBound), PanelMetrics.leftRange.upperBound)
        rightWidth = PanelDimension.rightWidth.clamp(rightWidth)
        terminalListWidth = min(max(terminalListWidth, PanelMetrics.terminalListRange.lowerBound), PanelMetrics.terminalListRange.upperBound)
        filesTreeWidth = min(max(filesTreeWidth, PanelMetrics.filesTreeRange.lowerBound), PanelMetrics.filesTreeRange.upperBound)
        if !LeftPane.available.contains(leftPane) { leftPane = .sessions }
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
/// 工作树项目与原项目的关联。
public struct WorktreeLink: Codable, Equatable, Sendable {
    /// 原项目(主检出)的项目 ID(目录路径)
    public var origin: String
    /// 工作树的分支
    public var branch: String
    /// 创建时主检出的提交(用于统计改动)
    public var base: String

    public init(origin: String, branch: String, base: String) {
        self.origin = origin
        self.branch = branch
        self.base = base
    }
}

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
    /// 已删除会话的墓碑 ID:引擎历史刷新时不再把它们加回侧栏(防止「删了又冒出来」)
    public var deletedSessions: [String] = []
    /// 是否为「会话区」:不绑定任何项目的通用对话(ChatGPT 式问答),工作目录是应用支持目录下的空目录。
    /// 它复用项目的会话机制(历史、置顶、归档、标签),但不出现在项目列表里。
    public var isChatArea = false
    /// 自定义侧栏图标(nil 为默认文件夹图标)
    public var icon: ProjectIcon?
    /// 工作区里额外的文件夹(绝对路径,不含主目录 `id`);Agent、搜索、文件树与 Git 面板会覆盖它们
    public var extraFolders: [String] = []
    /// 非 nil 表示这是某个项目的 Git 工作树(隔离检出);侧栏显示分支徽标
    public var worktree: WorktreeLink?

    public var url: URL { URL(fileURLWithPath: id) }

    public init(url: URL, now: Date = Date()) {
        id = url.standardizedFileURL.path
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        addedAt = now
        lastOpenedAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, addedAt, lastOpenedAt, pinned, collapsed, sessions, pinnedSessions, archivedSessions, deletedSessions, isChatArea, icon, extraFolders, worktree
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
        deletedSessions = try c.decodeIfPresent([String].self, forKey: .deletedSessions) ?? []
        isChatArea = try c.decodeIfPresent(Bool.self, forKey: .isChatArea) ?? false
        icon = try c.decodeIfPresent(ProjectIcon.self, forKey: .icon)
        extraFolders = try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? []
        worktree = try c.decodeIfPresent(WorktreeLink.self, forKey: .worktree)
    }
}

/// 一个会话标签在退出时的状态:重启后据此在原标签里恢复同一个会话(而不是新建空白会话)。
public struct ChatSlotRecord: Codable, Equatable, Sendable {
    public var projectID: String
    /// 标签槽位(nil 为项目主会话)
    public var slot: String?
    public var sessionId: String
    /// 会话所属引擎
    public var agentId: String?
    public var title: String?

    public init(projectID: String, slot: String?, sessionId: String, agentId: String?, title: String?) {
        self.projectID = projectID
        self.slot = slot
        self.sessionId = sessionId
        self.agentId = agentId
        self.title = title
    }

    /// 与 `ConversationKey` 对应的键。
    public var key: ConversationKey { ConversationKey(projectID: projectID, slot: slot) }
}

/// 持久化的工作台状态。
public struct WorkbenchState: Codable, Equatable, Sendable {
    public var layout = WorkbenchLayout()
    public var projects: [ProjectEntry] = []
    public var selectedProjectID: String?
    /// 停靠布局(旧版本状态文件没有该字段)
    public var dock: DockLayout?
    /// 右栏停靠布局(旧版本状态文件没有该字段)
    public var rightDock: DockLayout?
    /// 退出时仍有内容的会话标签(旧版本状态文件没有该字段)
    public var chatSlots: [ChatSlotRecord]?

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
        AppEnv.supportDirectory.appendingPathComponent("workbench.json")
    }

    /// 损坏状态文件的备份位置(`workbench.json.corrupt`)。
    public var corruptBackupURL: URL { fileURL.appendingPathExtension("corrupt") }

    /// 读取状态;文件不存在或损坏时返回 nil。
    /// 损坏(读取或解码失败)时先把原文件复制为 `corruptBackupURL` 并记录日志,避免随后的保存把唯一一份数据覆盖掉。
    public func load() -> WorkbenchState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var state = try decoder.decode(WorkbenchState.self, from: data)
            state.layout.clamp()
            return state
        } catch {
            Log.app.error("工作台状态读取失败,已备份并使用默认状态", error: error, ["file": fileURL.lastPathComponent, "backup": corruptBackupURL.lastPathComponent])
            backupCorruptFile()
            return nil
        }
    }

    /// 把损坏的状态文件复制为 `corruptBackupURL`(覆盖旧备份),失败只记日志。
    private func backupCorruptFile() {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: corruptBackupURL.path) { try fm.removeItem(at: corruptBackupURL) }
            try fm.copyItem(at: fileURL, to: corruptBackupURL)
        } catch {
            Log.app.error("备份损坏的工作台状态失败", error: error, ["backup": corruptBackupURL.lastPathComponent])
        }
    }

    /// 写入状态(编码 + 写盘;便捷入口,测试与迁移使用)。
    public func save(_ state: WorkbenchState) throws {
        try write(try encode(state))
    }

    /// 把状态编码为 JSON(不依赖文件系统,可在任意线程、任意锁外执行)。
    /// 不使用 `prettyPrinted`:状态含大量会话记录时,美化输出的体积与耗时都明显更高;`sortedKeys` 保证相同状态得到相同字节。
    /// - Parameter state: 状态快照
    public func encode(_ state: WorkbenchState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    /// 原子写入已编码的状态数据(自动创建目录)。
    /// - Parameter data: `encode(_:)` 的结果
    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
