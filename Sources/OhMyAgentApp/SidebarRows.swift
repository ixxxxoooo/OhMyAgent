// @author ixxxxoooo
// 项目栏的数据快照:把「置顶 / 会话 / 工作区 → 各项目 → 会话行」展平成一维行数组(`SidebarRow`),
// 配合 `SidebarWindowedList` 只挂载可见窗口内的行。生成过程只为「真正要显示的行」构造会话对象
// (折叠的项目只数个数,预览只取前 5 条),其余用轻量引用排序,50 项目 / 2000 会话下快照生成约几毫秒。

import ChatKit
import DesignSystem
import Foundation
import WorkbenchKit

/// 侧栏中的一行会话(由当前会话与历史缓存合并而来)。
struct SidebarSession: Identifiable, Equatable {
    var id: String { "\(projectID)#\(sessionId ?? uid ?? "new")" }
    let projectID: String
    /// 协议会话 ID;尚未产生消息的新对话为 nil(不可置顶/归档)
    let sessionId: String?
    let uid: String?
    let title: String
    let updatedAt: Date?
    let isCurrent: Bool
    let isRunning: Bool
    /// 会话所属 Agent;只在属于「别的引擎」时才有值(点击时据此切回原引擎打开;界面不显示引擎名)
    var foreignAgentID: String?
}

/// 项目会话列表的筛选方式。
enum SidebarSessionFilter {
    /// 只要置顶的会话
    case pinnedOnly
    /// 排除置顶,`showArchived` 决定是否含已归档
    case unpinned(showArchived: Bool)
}

/// 一个项目会话列表的快照结果。
struct SidebarSessionList {
    /// 要展示的会话(受 `limit` 截断)
    let items: [SidebarSession]
    /// 筛选后的会话总数
    let total: Int
    /// 筛选后全部会话的 ID(顺序与列表一致,用于「归档下方全部」);`limit == 0` 时为空
    let ids: [String?]
}

extension WorkbenchModel {
    /// 字符串数组转集合:逐个插入,避开 `Set.init(_:)` 泛型入口(热路径里会走 `swift_dynamicCast`,实测占列表重建的一半)。
    static func stringSet(_ values: [String]) -> Set<String> {
        var result = Set<String>(minimumCapacity: values.count)
        for value in values { result.insert(value) }
        return result
    }

    /// 排序用的轻量引用:不含任何要展示的字符串,只记排序键、会话 ID 与来源下标。
    private struct SessionRef {
        enum Source { case cached(Int), open(Int) }
        let key: Date
        let sessionId: String?
        let source: Source
    }

    /// 项目的会话列表:**只读持久化缓存**(`ProjectEntry.sessions`),按「创建时间」倒序,
    /// 与当前引擎、连接状态、引擎历史刷新都无关——切换引擎、点击会话、会话有新活动时顺序都不跳动。
    /// 当前会话若是尚未产生内容的空白对话,只在该项目被选中时显示为顶部的「新对话」。
    /// - Parameters:
    ///   - project: 项目
    ///   - filter: 置顶/归档筛选
    ///   - limit: 最多构造多少条会话对象(`nil` 为全部;`0` 只统计个数)
    @MainActor
    func sidebarSessionList(for project: ProjectEntry, filter: SidebarSessionFilter, limit: Int? = nil) -> SidebarSessionList {
        let model = sessions[project.id]
        // 该项目下所有已打开的会话(含尚无内容的空白新对话):点了「新对话」就是真实存在的会话,不随选中项目变化而消失
        let openModels = conversations.filter { $0.key.projectID == project.id }.map(\.value)
        // 只有存在已打开会话时才需要按 ID 查缓存条目(避免为 400 条缓存会话白建字典)
        let cache = openModels.isEmpty ? [:] : Dictionary(project.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        let currentAgent = model?.descriptor.id
        let deleted = Self.stringSet(project.deletedSessions)
        let openIDs = Self.stringSet(openModels.compactMap(\.sessionId))
        let pinned = project.pinnedSessions.isEmpty ? [] : Self.stringSet(project.pinnedSessions)
        let archived = project.archivedSessions.isEmpty ? [] : Self.stringSet(project.archivedSessions)
        func keep(_ id: String?) -> Bool {
            switch filter {
            case .pinnedOnly:
                guard let id else { return false }
                return pinned.contains(id)
            case .unpinned(let showArchived):
                guard let id else { return true }
                return !pinned.contains(id) && (showArchived || !archived.contains(id))
            }
        }

        var refs: [SessionRef] = []
        refs.reserveCapacity(project.sessions.count + openModels.count)
        for (index, item) in project.sessions.enumerated() {
            guard !openIDs.contains(item.sessionId), !EmptySessionRegistry.isHidden(item.sessionId),
                  !deleted.contains(item.sessionId), keep(item.sessionId) else { continue }
            refs.append(SessionRef(key: item.stableKey, sessionId: item.sessionId, source: .cached(index)))
        }
        for (index, open) in openModels.enumerated() where !deleted.contains(open.sessionId ?? "") && keep(open.sessionId) {
            let key = open.sessionId.flatMap { cache[$0] }?.stableKey ?? .distantFuture
            refs.append(SessionRef(key: key, sessionId: open.sessionId, source: .open(index)))
        }
        // 稳定排序:创建时间倒序(新对话 .distantFuture 排在最前);同键按原始相对顺序全序兜底
        let order = refs.indices.sorted { lhs, rhs in
            refs[lhs].key != refs[rhs].key ? refs[lhs].key > refs[rhs].key : lhs < rhs
        }
        let count = min(order.count, limit ?? order.count)
        let items: [SidebarSession] = order.prefix(count).map { position in
            switch refs[position].source {
            case .cached(let index):
                let item = project.sessions[index]
                let displayDate = Self.parseDate(item.updatedAt) ?? Self.parseDate(item.createdAt) ?? Self.parseDate(item.firstSeenAt)
                return SidebarSession(
                    projectID: project.id, sessionId: item.sessionId, uid: nil,
                    title: item.title ?? String(localized: "未命名对话"),
                    updatedAt: displayDate, isCurrent: false, isRunning: false,
                    foreignAgentID: item.agentId.flatMap { $0 != currentAgent ? $0 : nil }
                )
            case .open(let index):
                let open = openModels[index]
                let cached = open.sessionId.flatMap { cache[$0] }
                return SidebarSession(
                    projectID: project.id, sessionId: open.sessionId, uid: open.uid,
                    title: open.sessionTitle ?? cached?.title ?? String(localized: "新对话"),
                    updatedAt: nil, isCurrent: open === model, isRunning: open.isRunning
                )
            }
        }
        let ids: [String?] = limit == 0 ? [] : order.map { refs[$0].sessionId }
        return SidebarSessionList(items: items, total: order.count, ids: ids)
    }
}

/// 侧栏展平后的一行(分区标题、会话、提示、「显示更多」、项目分组标题)。
/// 侧栏行的范围:对应侧栏的两个模式。
enum SidebarScope: Equatable {
    /// 全部(旧行为,测试与基准使用)
    case all
    /// 会话模式:只含不绑定项目的通用会话
    case chat
    /// 代码模式:只含工作区(项目及其会话)
    case code

    /// 由侧栏模式得到范围。
    /// - Parameter pane: 侧栏模式
    init(pane: LeftPane) {
        self = pane == .workspaces ? .code : .chat
    }

    /// 该范围是否包含某一类条目。
    /// - Parameter chatArea: 条目是否属于会话区(通用会话)
    func includes(chatArea: Bool) -> Bool {
        switch self {
        case .all: return true
        case .chat: return chatArea
        case .code: return !chatArea
        }
    }
}

struct SidebarRow: Identifiable {
    /// 分区标题种类。
    enum TitleKind { case pinned, general, workspace }
    /// 提示文案种类。
    enum HintKind { case noGeneral, noWorkspace, noSessions }
    /// 行内容。
    enum Kind {
        case title(TitleKind)
        /// `siblings`/`index`:同列表全部会话 ID 与本行位置(右键「归档下方全部」按需取后缀,避免每行复制数组)
        case session(SidebarSession, mode: SessionLine.Mode, siblings: [String?], index: Int)
        case hint(HintKind, indent: CGFloat)
        case more(key: String, expanded: Bool, remaining: Int, indent: CGFloat)
        case project(ProjectEntry, count: Int)
    }

    let id: String
    let kind: Kind

    /// 固定内容高度(与各行视图内部的 frame 高度一致)。
    var height: Double {
        switch kind {
        case .title, .session, .project: 30
        case .hint, .more: 24
        }
    }

    /// 占位高度:内容高度 + 2pt 行间距(窗口化布局用前缀和,行间距并入行高)。
    var cellHeight: Double { height + 2 }
}

extension WorkbenchModel {
    /// 每个分组默认展示的会话条数,超出走「显示更多」。
    static let sidebarPreviewCount = 5
    /// 会话模式(通用会话)默认展示的条数:整个侧栏只有这一个列表,可以放得更多。
    static let sidebarGeneralPreviewCount = 20

    /// 某个列表默认展示的会话条数。
    /// - Parameter mode: 列表类型(通用会话用更大的上限)
    /// - Returns: 条数
    static func sidebarPreviewCount(for mode: SessionLine.Mode) -> Int {
        mode == .general ? sidebarGeneralPreviewCount : sidebarPreviewCount
    }

    /// 把侧栏展平为一维行数组(置顶 → 会话 → 工作区 → 各项目及其会话)。
    /// - Parameters:
    ///   - showArchived: 是否包含已归档会话
    ///   - expandedMore: 已点开「显示更多」的列表键(`general` 或项目 ID)
    ///   - scope: 行范围(会话模式 / 代码模式 / 全部)
    /// - Returns: 从上到下的行
    @MainActor
    func sidebarRows(showArchived: Bool, expandedMore: Set<String>, scope: SidebarScope = .all) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        // 置顶:只有登记了置顶会话的项目才需要构造会话行;会话模式只含通用会话,代码模式只含工作区会话
        let pinned = projects.filter { !$0.pinnedSessions.isEmpty && scope.includes(chatArea: $0.isChatArea) }.flatMap {
            sidebarSessionList(for: $0, filter: .pinnedOnly).items
        }
        if !pinned.isEmpty {
            rows.append(SidebarRow(id: "title:pinned", kind: .title(.pinned)))
            for item in pinned {
                rows.append(SidebarRow(id: "pin:\(item.id)", kind: .session(item, mode: .pinned, siblings: [], index: 0)))
            }
        }
        if scope.includes(chatArea: true) {
            rows.append(SidebarRow(id: "title:general", kind: .title(.general)))
            if let entry = projects.first(where: \.isChatArea) {
                appendSessions(of: entry, mode: .general, key: "general", indent: 8, showArchived: showArchived,
                               expandedMore: expandedMore, emptyHint: .noGeneral, collapsed: false, into: &rows)
            } else {
                rows.append(SidebarRow(id: "hint:general", kind: .hint(.noGeneral, indent: 8)))
            }
        }
        if scope.includes(chatArea: false) {
            rows.append(SidebarRow(id: "title:workspace", kind: .title(.workspace)))
            if workspaceProjects.isEmpty {
                rows.append(SidebarRow(id: "hint:workspace", kind: .hint(.noWorkspace, indent: 8)))
            }
            for project in orderedProjects {
                appendSessions(of: project, mode: .tree, key: project.id, indent: 16, showArchived: showArchived,
                               expandedMore: expandedMore, emptyHint: .noSessions, collapsed: project.collapsed, into: &rows)
            }
        }
        return rows
    }

    /// 追加一个列表:项目分组标题(工作区项目)+ 会话行(含空提示与「显示更多 / 收起」)。
    /// 折叠的项目只统计个数,不构造会话对象。
    @MainActor
    private func appendSessions(of project: ProjectEntry, mode: SessionLine.Mode, key: String, indent: CGFloat, showArchived: Bool,
                                expandedMore: Set<String>, emptyHint: SidebarRow.HintKind, collapsed: Bool, into rows: inout [SidebarRow]) {
        let expanded = expandedMore.contains(key)
        let preview = Self.sidebarPreviewCount(for: mode)
        let limit = collapsed ? 0 : (expanded ? nil : preview)
        let list = sidebarSessionList(for: project, filter: .unpinned(showArchived: showArchived), limit: limit)
        if mode == .tree { rows.append(SidebarRow(id: "project:\(project.id)", kind: .project(project, count: list.total))) }
        guard !collapsed else { return }
        if list.total == 0 { rows.append(SidebarRow(id: "hint:\(key)", kind: .hint(emptyHint, indent: indent))) }
        for (index, item) in list.items.enumerated() {
            rows.append(SidebarRow(id: "\(key):\(item.id)", kind: .session(item, mode: mode, siblings: list.ids, index: index)))
        }
        if list.total > preview {
            rows.append(SidebarRow(id: "more:\(key)", kind: .more(key: key, expanded: expanded, remaining: list.total - preview, indent: indent)))
        }
    }
}

