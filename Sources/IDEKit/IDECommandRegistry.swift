// @author ixxxxoooo
// IDE 命令注册表(无视图):命令 id/标题/分类/快捷键/可用条件,命令面板的模糊搜索与最近使用排序,
// 以及命令面板输入框前缀(`>` 命令、`:` 转到行、其余为文件)的解析。

import Foundation
import WorkbenchKit

/// 命令可用条件(对应 VS Code 的 `when` 上下文)。
public enum IDEWhen: String, Sendable, CaseIterable {
    /// 始终可用
    case always
    /// 窗口已打开文件夹
    case hasFolder
    /// 有活动的文件标签
    case hasActiveFile
    /// 存在未保存的文件
    case hasDirty
}

/// 命令执行时的上下文快照。
public struct IDECommandContext: Equatable, Sendable {
    public var hasFolder: Bool
    public var hasActiveFile: Bool
    public var hasDirty: Bool

    /// - Parameters:
    ///   - hasFolder: 是否打开了文件夹
    ///   - hasActiveFile: 是否有活动文件
    ///   - hasDirty: 是否有未保存文件
    public init(hasFolder: Bool = false, hasActiveFile: Bool = false, hasDirty: Bool = false) {
        self.hasFolder = hasFolder
        self.hasActiveFile = hasActiveFile
        self.hasDirty = hasDirty
    }

    /// 某条件在当前上下文里是否成立。
    /// - Parameter when: 条件
    public func satisfies(_ when: IDEWhen) -> Bool {
        switch when {
        case .always: true
        case .hasFolder: hasFolder
        case .hasActiveFile: hasActiveFile
        case .hasDirty: hasDirty
        }
    }
}

/// 一条 IDE 命令。
public struct IDECommand: Identifiable, Equatable, Sendable {
    /// 稳定的命令标识(如 `view.toggleSidebar`)
    public let id: String
    /// 面板里显示的标题(已本地化)
    public let title: String
    /// 分类(已本地化),显示在标题前
    public let category: String
    /// 快捷键的展示文本(如 `⌘S`),没有为 nil
    public let shortcut: String?
    /// 可用条件
    public let when: IDEWhen

    /// - Parameters:
    ///   - id: 命令标识
    ///   - title: 标题
    ///   - category: 分类
    ///   - shortcut: 快捷键展示
    ///   - when: 可用条件
    public init(id: String, title: String, category: String, shortcut: String? = nil, when: IDEWhen = .always) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.when = when
    }

    /// 参与搜索与展示的完整文本:`分类: 标题`。
    public var displayTitle: String { "\(category): \(title)" }
}

/// 命令搜索的一条结果。
public struct IDECommandMatch: Identifiable, Equatable, Sendable {
    public var id: String { command.id }
    public let command: IDECommand
    /// 命中的字符位置(以 `displayTitle` 的 Character 下标)
    public let positions: [Int]
}

/// 命令注册表:内置命令清单 + 最近使用记录。
public struct IDECommandRegistry: Sendable {
    /// 全部命令(按声明顺序)
    public private(set) var commands: [IDECommand]
    /// 最近执行过的命令标识(最近的在前,最多 `recentLimit` 个)
    public private(set) var recent: [String] = []
    /// 最近使用保留个数
    public static let recentLimit = 8

    /// - Parameter commands: 命令清单;默认为内置清单
    public init(commands: [IDECommand] = IDECommandRegistry.builtin) {
        self.commands = commands
    }

    /// 按标识取命令。
    /// - Parameter id: 命令标识
    public func command(id: String) -> IDECommand? { commands.first { $0.id == id } }

    /// 记录一次执行,把命令提到最近使用首位。
    /// - Parameter id: 命令标识
    public mutating func recordUse(_ id: String) {
        guard commands.contains(where: { $0.id == id }) else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// 搜索命令:过滤掉当前上下文不可用的;查询为空时最近使用在前,其余按声明顺序;否则按模糊得分降序。
    /// - Parameters:
    ///   - query: 查询(忽略大小写与空白)
    ///   - context: 上下文
    ///   - limit: 结果上限
    public func search(query: String, context: IDECommandContext, limit: Int = 50) -> [IDECommandMatch] {
        let available = commands.filter { context.satisfies($0.when) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
            let sorted = available.enumerated().sorted { lhs, rhs in
                switch (order[lhs.element.id], order[rhs.element.id]) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
            return sorted.prefix(limit).map { IDECommandMatch(command: $0.element, positions: []) }
        }
        let scored = available.compactMap { command -> (IDECommand, FuzzyMatch)? in
            FuzzyMatcher.match(query: trimmed, path: command.displayTitle).map { (command, $0) }
        }
        return scored
            .sorted { $0.1.score != $1.1.score ? $0.1.score > $1.1.score : $0.0.displayTitle < $1.0.displayTitle }
            .prefix(limit)
            .map { IDECommandMatch(command: $0.0, positions: $0.1.positions) }
    }

    /// 内置命令清单。
    public static var builtin: [IDECommand] {
        let file = String(localized: "文件"), view = String(localized: "视图"), edit = String(localized: "编辑")
        let go = String(localized: "转到"), terminal = String(localized: "终端"), agent = String(localized: "Agent")
        let window = String(localized: "窗口"), git = String(localized: "源代码管理")
        return [
            IDECommand(id: "file.save", title: String(localized: "保存"), category: file, shortcut: "⌘S", when: .hasActiveFile),
            IDECommand(id: "file.saveAll", title: String(localized: "全部保存"), category: file, shortcut: "⌥⌘S", when: .hasDirty),
            IDECommand(id: "file.closeTab", title: String(localized: "关闭标签"), category: file, shortcut: "⌘W", when: .hasActiveFile),
            IDECommand(id: "file.reopenTab", title: String(localized: "重新打开已关闭的标签"), category: file, shortcut: "⇧⌘T"),
            IDECommand(id: "file.newFile", title: String(localized: "新建文件"), category: file, when: .hasFolder),
            IDECommand(id: "file.newFolder", title: String(localized: "新建文件夹"), category: file, when: .hasFolder),
            IDECommand(id: "file.openFolder", title: String(localized: "打开文件夹…"), category: file, shortcut: "⌘O"),
            IDECommand(id: "go.quickOpen", title: String(localized: "转到文件…"), category: go, shortcut: "⌘P"),
            IDECommand(id: "go.line", title: String(localized: "转到行…"), category: go, shortcut: "⌃G", when: .hasActiveFile),
            IDECommand(id: "go.nextTab", title: String(localized: "下一个标签"), category: go, shortcut: "⌃Tab", when: .hasActiveFile),
            IDECommand(id: "go.previousTab", title: String(localized: "上一个标签"), category: go, shortcut: "⌃⇧Tab", when: .hasActiveFile),
            IDECommand(id: "go.revealActiveFile", title: String(localized: "在资源管理器中定位当前文件"), category: go, when: .hasActiveFile),
            IDECommand(id: "lsp.symbols", title: String(localized: "转到符号…"), category: go, shortcut: "⇧⌘O", when: .hasActiveFile),
            IDECommand(id: "lsp.references", title: String(localized: "查找引用"), category: go, shortcut: "⇧F12", when: .hasActiveFile),
            IDECommand(id: "lsp.rename", title: String(localized: "重命名符号"), category: edit, shortcut: "F2", when: .hasActiveFile),
            IDECommand(id: "lsp.codeAction", title: String(localized: "快速修复…"), category: edit, shortcut: "⌘.", when: .hasActiveFile),
            IDECommand(id: "lsp.format", title: String(localized: "格式化文档"), category: edit, shortcut: "⇧⌥F", when: .hasActiveFile),
            IDECommand(id: "edit.toggleComment", title: String(localized: "切换行注释"), category: edit, shortcut: "⌘/", when: .hasActiveFile),
            IDECommand(id: "edit.moveLineUp", title: String(localized: "向上移动行"), category: edit, shortcut: "⌥↑", when: .hasActiveFile),
            IDECommand(id: "edit.moveLineDown", title: String(localized: "向下移动行"), category: edit, shortcut: "⌥↓", when: .hasActiveFile),
            IDECommand(id: "edit.addNextOccurrence", title: String(localized: "添加下一个相同项"), category: edit, shortcut: "⌘D", when: .hasActiveFile),
            IDECommand(id: "edit.fold", title: String(localized: "折叠"), category: edit, shortcut: "⌥⌘[", when: .hasActiveFile),
            IDECommand(id: "edit.unfold", title: String(localized: "展开"), category: edit, shortcut: "⌥⌘]", when: .hasActiveFile),
            IDECommand(id: "edit.foldAll", title: String(localized: "全部折叠"), category: edit, when: .hasActiveFile),
            IDECommand(id: "edit.unfoldAll", title: String(localized: "全部展开"), category: edit, when: .hasActiveFile),
            IDECommand(id: "view.toggleSidebar", title: String(localized: "切换侧栏"), category: view, shortcut: "⌘B"),
            IDECommand(id: "view.togglePanel", title: String(localized: "切换底部面板"), category: view, shortcut: "⌘J"),
            IDECommand(id: "view.maximizeAgentPane", title: String(localized: "最大化 / 还原 Agent 面板"), category: view, shortcut: "⌥⌘E"),
            IDECommand(id: "view.perfHUD", title: String(localized: "显示 / 隐藏性能 HUD"), category: view),
            IDECommand(id: "view.toggleAgentPane", title: String(localized: "切换 Agent 面板"), category: view, shortcut: "⌥⌘B"),
            IDECommand(id: "view.explorer", title: String(localized: "显示资源管理器"), category: view, shortcut: "⇧⌘E", when: .hasFolder),
            IDECommand(id: "view.search", title: String(localized: "在文件中搜索"), category: view, shortcut: "⇧⌘F", when: .hasFolder),
            IDECommand(id: "view.scm", title: String(localized: "显示源代码管理"), category: view, shortcut: "⌃⇧G", when: .hasFolder),
            IDECommand(id: "view.problems", title: String(localized: "显示问题"), category: view, shortcut: "⇧⌘M"),
            IDECommand(id: "terminal.new", title: String(localized: "新建终端"), category: terminal, shortcut: "⌃⇧`"),
            IDECommand(id: "agent.newChat", title: String(localized: "新对话"), category: agent, when: .hasFolder),
            IDECommand(id: "agent.addFile", title: String(localized: "把当前文件加入对话"), category: agent, when: .hasActiveFile),
            IDECommand(id: "agent.openWindow", title: String(localized: "切换到 Agents Window"), category: agent, shortcut: "⌃⌘I"),
            IDECommand(id: "window.new", title: String(localized: "新建 IDE 窗口"), category: window, shortcut: "⇧⌘N"),
            IDECommand(id: "scm.refresh", title: String(localized: "刷新 Git 状态"), category: git, when: .hasFolder),
        ]
    }
}

/// 命令面板输入的解析结果。
public enum IDEPaletteQuery: Equatable, Sendable {
    /// 按文件名模糊打开
    case files(String)
    /// `>` 开头:命令
    case commands(String)
    /// `:行[:列]`:转到行(两者可缺省,缺省为 nil)
    case line(Int?, Int?)

    /// 解析输入框文本。
    /// - Parameter text: 输入
    public static func parse(_ text: String) -> IDEPaletteQuery {
        if text.hasPrefix(">") { return .commands(String(text.dropFirst())) }
        if text.hasPrefix(":") {
            let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            let line = parts.first.flatMap { $0 }
            let column = parts.count > 1 ? parts[1] : nil
            return .line(line.flatMap { $0 > 0 ? $0 : nil }, column.flatMap { $0 > 0 ? $0 : nil })
        }
        return .files(text)
    }

    /// 切换模式时给输入框补的前缀。
    public var prefix: String {
        switch self {
        case .files: ""
        case .commands: ">"
        case .line: ":"
        }
    }
}

/// 快速打开的排序:查询为空时「已打开的文件」优先(保持传入顺序),其余按路径;否则模糊得分降序。
public enum IDEQuickOpen {
    /// - Parameters:
    ///   - query: 查询
    ///   - files: 工作区相对路径全集
    ///   - recents: 最近/已打开的相对路径(最近的在前)
    ///   - limit: 上限
    public static func rank(query: String, files: [String], recents: [String], limit: Int = 50) -> [FuzzyMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recentSet = Set(recents)
            let head = recents.filter { files.contains($0) }
            let rest = files.filter { !recentSet.contains($0) }
            return (head + rest).prefix(limit).map { FuzzyMatch(path: $0, score: 0, positions: []) }
        }
        return FuzzyMatcher.rank(query: trimmed, in: files, limit: limit)
    }
}
