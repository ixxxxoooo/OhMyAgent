// @author ixxxxoooo
// 空会话登记:有些 Agent(如 Google Antigravity)在 `session/new` 时就落盘一个会话,
// 每开一个标签、每次连接都会在 `session/list` 里多出一条「没有任何消息」的会话,把侧栏刷成一排空行。
// 这里记录「客户端新建、还没发过消息」的会话 ID,列表与搜索里据此隐藏;首条消息发出后立即取消隐藏。
// 另外,打开历史会话回放后发现内容为空的,也登记进来(早期遗留的空会话由此自愈)。

import Foundation

/// 空会话登记表(持久化到 UserDefaults,最多保留 500 条)。
@MainActor
public enum EmptySessionRegistry {
    private static let key = "session.emptyIDs"
    private static let limit = 500
    private static var ids: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []
    private static var lookup: Set<String> = Set(ids)

    /// 该会话是否应在列表里隐藏。
    /// - Parameter sessionId: 协议会话 ID
    public static func isHidden(_ sessionId: String) -> Bool { lookup.contains(sessionId) }

    /// 登记为空会话(隐藏)。
    /// - Parameter sessionId: 协议会话 ID;空串忽略
    public static func hide(_ sessionId: String) {
        guard !sessionId.isEmpty, lookup.insert(sessionId).inserted else { return }
        ids.append(sessionId)
        if ids.count > limit {
            let dropped = ids.prefix(ids.count - limit)
            ids.removeFirst(ids.count - limit)
            for item in dropped { lookup.remove(item) }
        }
        persist()
    }

    /// 取消隐藏(会话有了内容)。
    /// - Parameter sessionId: 协议会话 ID
    public static func unhide(_ sessionId: String) {
        guard lookup.remove(sessionId) != nil else { return }
        ids.removeAll { $0 == sessionId }
        persist()
    }

    /// 是否为「引擎自动建出、从未有过对话」的占位会话:标题是 OpenCode 默认的
    /// `New session - <UTC 创建时间>`,且最后更新时间与标题里的创建时间相差不超过 5 秒。
    /// 有过对话的会话更新时间会明显晚于创建时间,不会被误判。
    /// - Parameters:
    ///   - title: 会话标题
    ///   - updatedAt: 最后更新时间(ISO8601);缺失时按占位处理
    /// - Returns: 是否应当隐藏
    public static func isPlaceholder(title: String?, updatedAt: String?) -> Bool {
        guard let title, title.hasPrefix(placeholderPrefix) else { return false }
        let stamp = String(title.dropFirst(placeholderPrefix.count)).trimmingCharacters(in: .whitespaces)
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let created = try? Date(stamp, strategy: format) else { return false }
        guard let updatedAt, !updatedAt.isEmpty else { return true }
        guard let updated = (try? Date(updatedAt, strategy: format)) ?? (try? Date(updatedAt, strategy: .iso8601)) else { return false }
        return abs(updated.timeIntervalSince(created)) <= 5
    }

    private static let placeholderPrefix = "New session - "

    private static func persist() { UserDefaults.standard.set(ids, forKey: key) }

    /// 仅测试使用:清空登记。
    static func resetForTesting() {
        ids = []
        lookup = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
