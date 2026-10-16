// @author ygw
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
    public static let shared = AttentionCenter()

    public private(set) var items: [String: AttentionItem] = [:]
    /// 当前被用户查看的会话(窗口为 key 且该会话可见)。
    public private(set) var focusedID: String?
    /// 某会话从运行变为未读完成时回调(应用层用于发系统通知)。
    @ObservationIgnored public var onFinished: ((AttentionItem) -> Void)?
    /// 任意状态变化后回调(托盘刷新)。
    @ObservationIgnored public var onChange: (() -> Void)?

    public init() {}

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
        Log.session.info("会话已读", ["id": String(id.prefix(8)), "project": item.project])
        onChange?()
    }

    /// 全部标记已读。
    public func markAllRead() {
        let unread = items.values.filter { $0.state == .unreadDone }.map(\.id)
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
        var list = sessions(defaults).filter { $0.sessionId != session.sessionId }
        list.insert(session, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(20))) { defaults.set(data, forKey: sessionsKey) }
    }

    /// 清空最近会话。
    public static func clearSessions(_ defaults: UserDefaults = RecentStore.defaults) { defaults.removeObject(forKey: sessionsKey) }

    /// 读取最近项目路径(新→旧,已不存在的目录会被过滤)。
    public static func projects(_ defaults: UserDefaults = RecentStore.defaults) -> [String] {
        let list = defaults.stringArray(forKey: projectsKey) ?? []
        return list.filter { FileManager.default.fileExists(atPath: $0) }
    }

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
