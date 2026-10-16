// @author ixxxxoooo
// 标签导航历史(浏览器语义的回退/前进栈,对齐 kuku 的 tabs-nav):纯值类型,便于测试。
// 只记录标签 ID;激活标签由 `WorkbenchModel` 负责。

import Foundation

/// 导航历史:相邻去重、从中间导航会截断「前进」记录、超限裁剪最旧记录。
public struct NavHistory: Equatable, Sendable {
    /// 历史上限(对齐浏览器行为,防止无限增长)
    public static let limit = 50

    public private(set) var entries: [UUID] = []
    /// 当前位置;空历史为 -1
    public private(set) var cursor = -1

    public init() {}

    /// 可以后退。
    public var canGoBack: Bool { cursor > 0 }
    /// 可以前进。
    public var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }

    /// 记录一次导航。
    /// - Parameter id: 被激活的标签 ID(与当前记录相同则忽略)
    public mutating func push(_ id: UUID) {
        if entries.indices.contains(cursor), entries[cursor] == id { return }
        var next = Array(entries.prefix(cursor + 1))
        next.append(id)
        if next.count > Self.limit { next.removeFirst(next.count - Self.limit) }
        entries = next
        cursor = next.count - 1
    }

    /// 后退一步。
    /// - Returns: 目标标签 ID;无法后退时为 nil
    public mutating func back() -> UUID? {
        guard canGoBack else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// 前进一步。
    /// - Returns: 目标标签 ID;无法前进时为 nil
    public mutating func forward() -> UUID? {
        guard canGoForward else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// 清理已关闭的标签:移除不在 `alive` 中的记录,并修正游标
    /// (当前记录被移除时回退到最近保留的前驱,没有前驱则取后继)。
    /// - Parameter alive: 仍然存在的标签 ID
    public mutating func prune(alive: Set<UUID>) {
        guard entries.contains(where: { !alive.contains($0) }) else { return }
        let kept = entries.filter { alive.contains($0) }
        guard !kept.isEmpty else {
            entries = []
            cursor = -1
            return
        }
        let old = entries
        let removedBefore = { (end: Int) in old.prefix(end).filter { !alive.contains($0) }.count }
        if entries.indices.contains(cursor), alive.contains(entries[cursor]) {
            cursor -= removedBefore(cursor)
        } else if let previous = (0..<max(cursor, 0)).reversed().first(where: { alive.contains(entries[$0]) }) {
            cursor = previous - removedBefore(previous)
        } else {
            cursor = max(0, min(cursor - removedBefore(max(cursor, 0)), kept.count - 1))
        }
        entries = kept
    }
}
