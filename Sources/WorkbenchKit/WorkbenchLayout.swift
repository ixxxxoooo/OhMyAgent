// @author ygw
// 工作台布局与持久化模型:三栏 + 底部面板的显隐/尺寸/当前视图,以及项目列表。

import Foundation

/// 左栏视图。
public enum LeftPane: String, Codable, CaseIterable, Sendable {
    case sessions, files, git, search

    /// 已实现的视图(随里程碑逐步开放)。
    public static var available: [LeftPane] { [.sessions] }
}

/// 右栏视图。
public enum RightPane: String, Codable, CaseIterable, Sendable {
    case changes, plan, outline, problems

    public static var available: [RightPane] { [.changes, .plan] }
}

/// 底部面板视图。
public enum BottomPane: String, Codable, CaseIterable, Sendable {
    case terminal, output, problems

    public static var available: [BottomPane] { [.output] }
}

/// 工作台布局。
public struct WorkbenchLayout: Codable, Equatable, Sendable {
    public var leftVisible = true
    public var rightVisible = false
    public var bottomVisible = false
    public var leftWidth: Double = 260
    public var rightWidth: Double = 340
    public var bottomHeight: Double = 240
    public var leftPane: LeftPane = .sessions
    public var rightPane: RightPane = .changes
    public var bottomPane: BottomPane = .output

    public init() {}

    /// 限制各尺寸在合理范围内(防止损坏的状态文件导致不可见的面板)。
    public mutating func clamp() {
        leftWidth = min(max(leftWidth, 200), 420)
        rightWidth = min(max(rightWidth, 260), 640)
        bottomHeight = min(max(bottomHeight, 120), 600)
        if !LeftPane.available.contains(leftPane) { leftPane = .sessions }
        if !RightPane.available.contains(rightPane) { rightPane = .changes }
        if !BottomPane.available.contains(bottomPane) { bottomPane = .output }
    }
}

/// 项目内缓存的历史会话(使项目树无需启动 Agent 即可展示)。
public struct CachedSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var title: String?
    public var updatedAt: String?

    public init(sessionId: String, title: String?, updatedAt: String?) {
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
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

    public var url: URL { URL(fileURLWithPath: id) }

    public init(url: URL, now: Date = Date()) {
        id = url.standardizedFileURL.path
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        addedAt = now
        lastOpenedAt = now
    }
}

/// 持久化的工作台状态。
public struct WorkbenchState: Codable, Equatable, Sendable {
    public var layout = WorkbenchLayout()
    public var projects: [ProjectEntry] = []
    public var selectedProjectID: String?

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
