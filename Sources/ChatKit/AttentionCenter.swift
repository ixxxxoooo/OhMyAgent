// @author ixxxxoooo
// 注意力中心:汇总各会话的「运行中 / 待处理 / 未读完成」状态,驱动托盘状态点、Dock 角标与侧栏状态点。
// 规则:运行时点闪烁;运行结束后未被查看则常亮;用户打开对应会话或点击通知后消失。

import Foundation
import os
import Observation
import OMLog

/// 单个会话的注意力状态。
public enum AttentionState: Int, Sendable, Comparable {
    case idle = 0
    case unreadDone = 1
    case running = 2
    case needsInput = 3

    public static func < (lhs: AttentionState, rhs: AttentionState) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 托盘上的汇总指示。
public enum TrayIndicator: Sendable, Equatable {
    /// 无状态点
    case none
    /// 有会话在运行:点闪烁
    case running
    /// 有会话在等待授权或回答:橙色点闪烁
    case needsInput
    /// 有未读的完成结果:点常亮
    case unread
}

/// 注意力条目。
public struct AttentionItem: Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var project: String
    public var workspacePath: String
    public var sessionId: String?
    public var state: AttentionState
    public var updatedAt: Date
}

/// 注意力中心(主线程使用的单例,测试可自建)。
@MainActor
@Observable
public final class AttentionCenter {
    public static let shared = AttentionCenter(persistUnread: true)

    public private(set) var items: [String: AttentionItem] = [:]
    /// 当前被用户查看的会话(窗口为 key 且该会话可见)。
    public private(set) var focusedID: String?
    /// 某会话从运行变为未读完成时回调(应用层用于发系统通知)。
    @ObservationIgnored public var onFinished: ((AttentionItem) -> Void)?
    /// 任意状态变化后回调(托盘刷新)。
    @ObservationIgnored public var onChange: (() -> Void)?

    /// 是否把未读会话 ID 持久化到 `RecentStore`(托盘「最近会话」重启后仍能显示未读标识);测试默认关闭。
    @ObservationIgnored private let persistUnread: Bool

    /// - Parameter persistUnread: 是否持久化未读标记
    public init(persistUnread: Bool = false) { self.persistUnread = persistUnread }

    /// 汇总指示:待处理 > 运行中 > 未读 > 无。
    public var indicator: TrayIndicator {
        let top = items.values.map(\.state).max() ?? .idle
        switch top {
        case .needsInput: return .needsInput
        case .running: return .running
        case .unreadDone: return .unread
        case .idle: return .none
        }
    }

    /// 各状态的会话数量。
    public func count(of state: AttentionState) -> Int { items.values.filter { $0.state == state }.count }

    /// 按状态优先、时间倒序排列的条目。
    public var sortedItems: [AttentionItem] {
        items.values.sorted { ($0.state, $0.updatedAt) > ($1.state, $1.updatedAt) }
    }

    /// 由会话模型在运行/权限状态变化时调用。
    /// - Parameters:
    ///   - id: 会话唯一标识(进程内)
    ///   - title: 展示标题
    ///   - project: 项目名
    ///   - workspacePath: 项目路径
    ///   - sessionId: ACP 会话 ID
    ///   - running: 是否正在运行一轮
    ///   - needsInput: 是否有待处理的权限/提问
    public func update(id: String, title: String, project: String, workspacePath: String, sessionId: String?, running: Bool, needsInput: Bool) {
        let previous = items[id]?.state ?? .idle
        var next: AttentionState
        if needsInput { next = .needsInput }
        else if running { next = .running }
        else if previous == .running || previous == .needsInput { next = focusedID == id ? .idle : .unreadDone }
        else { next = previous == .unreadDone ? .unreadDone : .idle }
        if focusedID == id, next == .unreadDone { next = .idle }
        let item = AttentionItem(id: id, title: title, project: project, workspacePath: workspacePath, sessionId: sessionId, state: next, updatedAt: Date())
        let changed = items[id]?.state != next
        if next == .idle, items[id] == nil { return }
        items[id] = item
        if next == .idle { items[id] = nil }
        if persistUnread, let sid = sessionId {
            // 仅在「被查看」时清除;后台会话空闲更新不能抹掉上次启动遗留的未读
            if next == .unreadDone { RecentStore.markUnread(sid) } else if focusedID == id, next == .idle { RecentStore.clearUnread(sid) }
        }
        if changed {
            Log.session.info("注意力状态变化", ["id": String(id.prefix(8)), "project": project, "from": "\(previous)", "to": "\(next)"])
            if next == .unreadDone { onFinished?(item) }
            onChange?()
        }
    }

    /// 标记已读(打开会话或点击通知)。
    /// - Parameter id: 会话标识
    public func markRead(_ id: String) {
        guard var item = items[id], item.state == .unreadDone else { return }
        item.state = .idle
        items[id] = nil
        if persistUnread, let sid = item.sessionId { RecentStore.clearUnread(sid) }
        Log.session.info("会话已读", ["id": String(id.prefix(8)), "project": item.project])
        onChange?()
    }

    /// 全部标记已读。
    public func markAllRead() {
        let unread = items.values.filter { $0.state == .unreadDone }.map(\.id)
        for id in unread { markRead(id) }
    }

    /// 把某个工作区下的未读全部标记已读。
    /// - Parameter workspacePath: 工作区(项目)路径
    public func markAllRead(inWorkspace workspacePath: String) {
        let unread = items.values.filter { $0.state == .unreadDone && $0.workspacePath == workspacePath }.map(\.id)
        for id in unread { markRead(id) }
    }

    /// 设置当前被查看的会话;若该会话有未读则立即清除。
    /// - Parameter id: 会话标识;nil 表示没有会话被查看
    public func setFocus(_ id: String?) {
        focusedID = id
        if let id { markRead(id) }
    }

    /// 会话关闭:未读完成的条目保留(用户仍需要看到),其余移除。
    /// - Parameter id: 会话标识
    public func sessionClosed(_ id: String) {
        guard let item = items[id] else { return }
        if item.state != .unreadDone { items[id] = nil; onChange?() }
    }
}

/// 最近会话记录(跨启动持久化,供托盘与欢迎页使用)。
public struct RecentSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public var workspacePath: String
    public var sessionId: String
    public var title: String
    public var date: Date
}

/// 最近会话与最近项目存储(UserDefaults)。
public enum RecentStore {
    static let sessionsKey = "recent.sessions"
    static let projectsKey = "recent.projects"
    static let unreadKey = "recent.unreadSessions"

    private static let suiteName = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// 默认存储:未指定 suite 时为 `UserDefaults.standard`;演示模式启动时改用独立 suite,避免污染真实的最近项目/会话。
    public static var defaults: UserDefaults {
        guard let name = suiteName.withLock({ $0 }) else { return .standard }
        return UserDefaults(suiteName: name) ?? .standard
    }

    /// 切换默认存储所用的 suite。
    /// - Parameter name: suite 名称;nil 恢复为 `UserDefaults.standard`
    public static func useSuite(_ name: String?) { suiteName.withLock { $0 = name } }

    /// 读取最近会话(新→旧)。
    /// - Parameter defaults: 存储
    public static func sessions(_ defaults: UserDefaults = RecentStore.defaults) -> [RecentSession] {
        guard let data = defaults.data(forKey: sessionsKey), let list = try? JSONDecoder().decode([RecentSession].self, from: data) else { return [] }
        return list.sorted { $0.date > $1.date }
    }

    /// 记录一次会话(同 sessionId 去重,最多保留 20 条)。
    public static func record(_ session: RecentSession, _ defaults: UserDefaults = RecentStore.defaults) {
        guard !session.sessionId.isEmpty, !session.workspacePath.isEmpty else { return }
        let span = Log.perf.span("记录最近会话", warnMs: 16, quiet: true)
        defer { span.end() }
        var list = sessions(defaults).filter { $0.sessionId != session.sessionId }
        list.insert(session, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(20))) { defaults.set(data, forKey: sessionsKey) }
    }

    /// 从最近会话里移除某个会话(用户删除会话后调用)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - defaults: 存储
    public static func removeSession(_ sessionId: String, _ defaults: UserDefaults = RecentStore.defaults) {
        let list = sessions(defaults)
        guard list.contains(where: { $0.sessionId == sessionId }) else { return }
        if let data = try? JSONEncoder().encode(list.filter { $0.sessionId != sessionId }) { defaults.set(data, forKey: sessionsKey) }
    }

    /// 读取未读完成的会话 ID 集合(跨启动保留)。
    /// - Parameter defaults: 存储
    public static func unreadSessionIDs(_ defaults: UserDefaults = RecentStore.defaults) -> Set<String> {
        Set(defaults.stringArray(forKey: unreadKey) ?? [])
    }

    /// 标记某会话有未读完成结果(最多保留 50 个,超出时丢弃最早的)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID(空串忽略)
    ///   - defaults: 存储
    public static func markUnread(_ sessionId: String, _ defaults: UserDefaults = RecentStore.defaults) {
        guard !sessionId.isEmpty else { return }
        var list = (defaults.stringArray(forKey: unreadKey) ?? []).filter { $0 != sessionId }
        list.append(sessionId)
        defaults.set(Array(list.suffix(50)), forKey: unreadKey)
    }

    /// 清除某会话的未读标记。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - defaults: 存储
    public static func clearUnread(_ sessionId: String, _ defaults: UserDefaults = RecentStore.defaults) {
        guard let list = defaults.stringArray(forKey: unreadKey), list.contains(sessionId) else { return }
        defaults.set(list.filter { $0 != sessionId }, forKey: unreadKey)
    }

    /// 清空最近会话。
    public static func clearSessions(_ defaults: UserDefaults = RecentStore.defaults) { defaults.removeObject(forKey: sessionsKey) }

    /// 读取最近项目路径(新→旧,已不存在的目录会被过滤)。
    public static func projects(_ defaults: UserDefaults = RecentStore.defaults) -> [String] {
        let list = defaults.stringArray(forKey: projectsKey) ?? []
        // 目录是否存在的检查最多 12 次 `fileExists`(磁盘 I/O),而本函数会在视图 body 里被反复调用:
        // 原始列表没变且距上次检查不到 TTL 时直接复用结果(目录被删除最迟 TTL 后体现)
        let now = ContinuousClock.now
        let owner = ObjectIdentifier(defaults)
        if let hit = projectsCache.withLock({ cache -> [String]? in
            guard let cache, cache.owner == owner, cache.raw == list, now - cache.at < projectsCacheTTL else { return nil }
            return cache.filtered
        }) { return hit }
        let filtered = list.filter { FileManager.default.fileExists(atPath: $0) }
        projectsCache.withLock { $0 = ProjectsCache(owner: owner, raw: list, filtered: filtered, at: now) }
        return filtered
    }

    /// 最近项目存在性检查的缓存有效期。
    static let projectsCacheTTL: Duration = .seconds(5)

    private struct ProjectsCache: Sendable {
        let owner: ObjectIdentifier
        let raw: [String]
        let filtered: [String]
        let at: ContinuousClock.Instant
    }
    private static let projectsCache = OSAllocatedUnfairLock<ProjectsCache?>(initialState: nil)

    /// 丢弃最近项目缓存(测试用)。
    static func resetProjectsCache() { projectsCache.withLock { $0 = nil } }

    /// 记录项目(去重置顶,最多 12 个)。
    public static func recordProject(_ path: String, _ defaults: UserDefaults = RecentStore.defaults) {
        guard !path.isEmpty else { return }
        var list = (defaults.stringArray(forKey: projectsKey) ?? []).filter { $0 != path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(12)), forKey: projectsKey)
    }

    /// 清空最近项目。
    public static func clearProjects(_ defaults: UserDefaults = RecentStore.defaults) { defaults.removeObject(forKey: projectsKey) }
}
