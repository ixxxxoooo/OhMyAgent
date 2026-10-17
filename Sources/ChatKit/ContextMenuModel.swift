// @author ixxxxoooo
// 右键菜单的数据模型与键盘导航(无视图,可单测):条目、分隔线、分组标题、可展开的子菜单。

import Foundation

/// 菜单条目。
public struct MenuEntry: Identifiable {
    /// 条目类型。
    public enum Kind {
        case item
        case divider
        case header
        case submenu([MenuEntry])
    }

    /// 在整棵菜单树内唯一(由 `MenuEntry.assignIDs` 按路径生成)。
    public var id: String
    public var kind: Kind
    public var title: String
    /// Lucide 图标语义名
    public var icon: String?
    /// 右侧快捷键提示(如 ⌘N)
    public var shortcut: String?
    public var isDestructive: Bool
    public var isEnabled: Bool
    /// 非 nil 时右侧显示勾选状态
    public var isChecked: Bool?
    public var action: (@MainActor () -> Void)?

    public init(id: String = "", kind: Kind = .item, title: String = "", icon: String? = nil, shortcut: String? = nil,
                isDestructive: Bool = false, isEnabled: Bool = true, isChecked: Bool? = nil, action: (@MainActor () -> Void)? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }

    /// 是否可被键盘选中(分隔线、标题、禁用项不可选)。
    public var isSelectable: Bool {
        switch kind {
        case .divider, .header: return false
        case .item, .submenu: return isEnabled
        }
    }

    /// 为整棵菜单树按路径赋予稳定 ID,并清理首尾与连续的分隔线。
    /// - Parameter entries: 原始条目
    /// - Returns: 规整后的条目
    public static func normalized(_ entries: [MenuEntry], prefix: String = "") -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries {
            if case .divider = entry.kind, result.isEmpty || { if case .divider = result[result.count - 1].kind { return true } else { return false } }() { continue }
            result.append(entry)
        }
        while let last = result.last, case .divider = last.kind { result.removeLast() }
        return result.enumerated().map { index, entry in
            var copy = entry
            copy.id = prefix + String(index)
            if case .submenu(let children) = entry.kind {
                copy.kind = .submenu(normalized(children, prefix: copy.id + "."))
            }
            return copy
        }
    }
}

/// 菜单中可见的一行(含子菜单展开后的子项)。
public struct MenuRow: Identifiable {
    public var entry: MenuEntry
    /// 缩进层级:0 为顶层,1 为展开的子菜单项
    public var depth: Int
    public var id: String { entry.id }
}

/// 键盘激活结果。
public enum MenuActivation {
    /// 执行动作(调用方应先关闭菜单再执行)
    case run(@MainActor () -> Void)
    /// 仅展开/折叠了子菜单
    case toggled
    /// 无事发生
    case none
}

/// 菜单状态:高亮、展开与按键导航。
public struct ContextMenuState {
    public private(set) var entries: [MenuEntry]
    public private(set) var highlightedID: String?
    public private(set) var expanded: Set<String> = []

    /// - Parameter entries: 菜单条目(内部会规整并赋予 ID)
    public init(entries: [MenuEntry]) {
        self.entries = MenuEntry.normalized(entries)
    }

    /// 当前可见行(按顺序,展开的子菜单紧跟其后)。
    public var rows: [MenuRow] {
        var result: [MenuRow] = []
        for entry in entries {
            result.append(MenuRow(entry: entry, depth: 0))
            if case .submenu(let children) = entry.kind, expanded.contains(entry.id) {
                result.append(contentsOf: children.map { MenuRow(entry: $0, depth: 1) })
            }
        }
        return result
    }

    private var selectableRows: [MenuRow] { rows.filter { $0.entry.isSelectable } }

    /// 移动高亮(跳过分隔线/标题/禁用项),到头不循环。
    /// - Parameter delta: 正为向下,负为向上
    public mutating func move(_ delta: Int) {
        let list = selectableRows
        guard !list.isEmpty else { return }
        guard let current = highlightedID, let index = list.firstIndex(where: { $0.id == current }) else {
            highlightedID = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        highlightedID = list[min(max(index + delta, 0), list.count - 1)].id
    }

    /// 鼠标悬停高亮(忽略不可选项)。
    public mutating func highlight(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), row.entry.isSelectable else { return }
        highlightedID = id
    }

    /// 激活高亮项(回车);也用于鼠标点击。
    /// - Parameter id: 指定条目;nil 表示当前高亮项
    public mutating func activate(_ id: String? = nil) -> MenuActivation {
        guard let target = id ?? highlightedID, let row = rows.first(where: { $0.id == target }), row.entry.isSelectable else { return .none }
        switch row.entry.kind {
        case .submenu:
            toggle(row.entry.id)
            highlightedID = row.entry.id
            return .toggled
        case .item:
            return row.entry.action.map { .run($0) } ?? .none
        case .divider, .header:
            return .none
        }
    }

    /// 向右:展开高亮的子菜单,并把高亮移到第一个子项。
    public mutating func expandHighlighted() {
        guard let id = highlightedID, let row = rows.first(where: { $0.id == id }),
              case .submenu(let children) = row.entry.kind, !expanded.contains(id) else { return }
        expanded.insert(id)
        if let first = children.first(where: { $0.isSelectable }) { highlightedID = first.id }
    }

    /// 向左:在子项里时折叠父子菜单并回到父项;在已展开的父项上时折叠它。
    public mutating func collapseHighlighted() {
        guard let id = highlightedID else { return }
        if let dot = id.lastIndex(of: ".") {
            let parent = String(id[..<dot])
            expanded.remove(parent)
            highlightedID = parent
        } else if expanded.contains(id) {
            expanded.remove(id)
        }
    }

    private mutating func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
