// @author ixxxxoooo
// Files 工作区内部的文件导航栈(← → 按钮的数据层):纯值类型,与全局标签 `NavHistory` 相互独立。

import Foundation

/// 文件导航栈:相邻去重、从中间导航会截断「前进」记录、超限裁剪最旧记录。
public struct FilesNavStack: Equatable, Sendable {
    /// 历史上限
    public static let limit = 50

    /// 依次访问过的文件绝对路径
    public private(set) var entries: [String] = []
    /// 当前位置;空栈为 -1
    public private(set) var cursor = -1

    public init() {}

    /// 当前文件路径;空栈为 nil。
    public var current: String? { entries.indices.contains(cursor) ? entries[cursor] : nil }
    /// 可以后退。
    public var canGoBack: Bool { cursor > 0 }
    /// 可以前进。
    public var canGoForward: Bool { cursor >= 0 && cursor < entries.count - 1 }

    /// 记录一次打开(与当前相同则忽略;空路径忽略)。
    /// - Parameter path: 文件绝对路径
    public mutating func push(_ path: String) {
        guard !path.isEmpty, path != current else { return }
        var next = Array(entries.prefix(cursor + 1))
        next.append(path)
        if next.count > Self.limit { next.removeFirst(next.count - Self.limit) }
        entries = next
        cursor = next.count - 1
    }

    /// 后退一步。
    /// - Returns: 目标路径;无法后退为 nil
    @discardableResult
    public mutating func back() -> String? {
        guard canGoBack else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// 前进一步。
    /// - Returns: 目标路径;无法前进为 nil
    @discardableResult
    public mutating func forward() -> String? {
        guard canGoForward else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// 清除所有满足条件的记录(文件被删除/重命名后),并修正游标:
    /// 当前记录被移除时回退到最近保留的前驱,没有前驱则取后继。
    /// - Parameter shouldRemove: 判定闭包
    public mutating func remove(where shouldRemove: (String) -> Bool) {
        guard entries.contains(where: shouldRemove) else { return }
        let currentPath = current
        // 游标之前被移除的条数,用于平移游标
        var kept: [String] = []
        var newCursor = -1
        for (index, path) in entries.enumerated() {
            if shouldRemove(path) { continue }
            kept.append(path)
            if index <= cursor { newCursor = kept.count - 1 }
        }
        // 相邻重复(移除中间项后可能出现)合并
        var deduped: [String] = []
        var adjusted = newCursor
        for (index, path) in kept.enumerated() {
            if deduped.last == path {
                if index <= newCursor { adjusted -= 1 }
                continue
            }
            deduped.append(path)
        }
        entries = deduped
        if deduped.isEmpty { cursor = -1; return }
        if let currentPath, !shouldRemove(currentPath) {
            cursor = max(0, min(adjusted, deduped.count - 1))
        } else {
            cursor = max(0, min(adjusted < 0 ? 0 : adjusted, deduped.count - 1))
        }
    }

    /// 清空。
    public mutating func reset() {
        entries = []
        cursor = -1
    }
}
