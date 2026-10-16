// @author ixxxxoooo
// 标签快捷操作的纯逻辑:关闭栈(⌘⇧T 恢复)、⌘1–9 下标换算、⌃Tab 循环。无视图、可测试。

import Foundation

/// 已关闭标签的记录(只保留重新打开所需信息)。
public struct ClosedTab: Equatable, Sendable {
    public var kind: TabKind
    public var title: String
    public var line: Int?

    public init(kind: TabKind, title: String, line: Int? = nil) {
        self.kind = kind
        self.title = title
        self.line = line
    }
}

/// 关闭栈:后进先出,去重(同一内容只保留最近一次),有容量上限。
public struct ClosedTabStack: Equatable, Sendable {
    public private(set) var items: [ClosedTab] = []
    public let capacity: Int

    public init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    /// 记录一次关闭。
    /// - Parameter tab: 被关闭的标签
    public mutating func push(_ tab: WorkbenchTab) {
        guard Self.isRestorable(tab.kind) else { return }
        items.removeAll { $0.kind == tab.kind }
        items.append(ClosedTab(kind: tab.kind, title: tab.title, line: tab.line))
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    /// 弹出最近关闭的一项;没有时为 nil。
    public mutating func pop() -> ClosedTab? { items.popLast() }

    /// 是否可重新打开:终端与 Agent 终端的进程已不在,不记录。
    public static func isRestorable(_ kind: TabKind) -> Bool {
        switch kind {
        case .terminal, .agentTerminal, .preview: return false
        default: return true
        }
    }
}

/// 标签导航的下标换算。
public enum TabNavigation {
    /// ⌘1–9:第 n 个标签;⌘9 固定为最后一个(与浏览器、VS Code 一致)。
    /// - Parameters:
    ///   - number: 1–9
    ///   - count: 标签总数
    /// - Returns: 0 起的下标;越界或没有标签时为 nil
    public static func index(forShortcut number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return count - 1 }
        return number - 1 < count ? number - 1 : nil
    }

    /// ⌃Tab / ⌃⇧Tab:循环切换。
    /// - Parameters:
    ///   - current: 当前下标
    ///   - delta: +1 下一个,-1 上一个
    ///   - count: 标签总数
    public static func cycled(from current: Int, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = (0..<count).contains(current) ? current : 0
        return ((base + delta) % count + count) % count
    }
}
