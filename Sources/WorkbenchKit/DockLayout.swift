// @author ixxxxoooo
// 停靠布局模型(纯值类型,可测试、可持久化):标签、标签组、分屏树及其全部操作。
// 视图层(DockView/TabBar)只负责渲染与手势,所有结构变更都经由这里,保证不变量:
//  1. 任意时刻至少存在一个标签组(可为空);除根组外不存在空组;
//  2. 同一内容(TabKind 相同)全局只存在一个标签;
//  3. 每个组的 activeID 指向组内存在的标签;分屏的 ratios 为正且和为 1。

import Foundation

/// 标签承载的内容类型(同一类型且参数相同视为同一内容)。
public enum TabKind: Codable, Hashable, Sendable {
    /// 项目会话
    case chat(projectID: String)
    /// 子 Agent 的只读完整会话
    case subagent(projectID: String, toolCallID: String)
    /// 文件(行号等导航状态存放在标签上,不参与身份)
    case file(path: String)
    /// 单个文件的差异
    case diff(path: String)
    /// 本轮改动汇总
    case changes(projectID: String)
    /// 终端
    case terminal(id: String)
    /// Agent 正在使用的终端(只读查看输出)
    case agentTerminal(projectID: String, terminalID: String)
    /// 预览(Mermaid / Markdown 放大等)
    case preview(id: String)
    /// Git 提交历史与图(`path` 非空时只看该文件的历史)
    case history(projectID: String, path: String?)
    /// 文件逐行追溯(blame)
    case blame(path: String)
}

/// 工作台标签。
public struct WorkbenchTab: Codable, Hashable, Identifiable, Sendable {
    /// 终端标签的终端标识;其他类型为 nil。
    public var terminalID: String? {
        if case .terminal(let id) = kind { return id }
        return nil
    }

    public var id: UUID
    public var kind: TabKind
    public var title: String
    /// 预览标签:斜体显示,再次预览其它文件时被替换;编辑或双击后固化
    public var isPreview: Bool
    /// 固定标签:排在组内最前,不被「关闭其它」关闭
    public var isPinned: Bool
    /// 未保存修改
    public var isDirty: Bool
    /// 打开时要定位的行号(1 起,可空)
    public var line: Int?

    public init(id: UUID = UUID(), kind: TabKind, title: String, isPreview: Bool = false, isPinned: Bool = false, isDirty: Bool = false, line: Int? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isPreview = isPreview
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.line = line
    }
}

/// 标签组:一条标签栏及其内容区。
public struct TabGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [WorkbenchTab]
    public var activeID: UUID?

    public init(id: UUID = UUID(), tabs: [WorkbenchTab] = [], activeID: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeID = activeID ?? tabs.first?.id
    }

    /// 当前激活的标签。
    public var active: WorkbenchTab? { tabs.first { $0.id == activeID } }
}

/// 分屏方向:horizontal 表示子节点从左到右排列。
public enum DockAxis: String, Codable, Sendable { case horizontal, vertical }

/// 分屏节点。
public struct DockSplit: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var axis: DockAxis
    public var children: [DockNode]
    /// 各子节点占比(与 children 等长,和为 1)
    public var ratios: [Double]

    public init(id: UUID = UUID(), axis: DockAxis, children: [DockNode], ratios: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        let n = max(children.count, 1)
        self.ratios = ratios ?? Array(repeating: 1.0 / Double(n), count: children.count)
    }
}

/// 停靠树节点。
public indirect enum DockNode: Codable, Hashable, Sendable {
    case group(TabGroup)
    case split(DockSplit)
}

extension DockNode: Identifiable {
    /// 节点身份:组或分屏自身的 ID(视图遍历稳定)。
    public var id: UUID {
        switch self {
        case .group(let g): return g.id
        case .split(let s): return s.id
        }
    }
}

/// 拖拽落点:中心表示并入该组;四边表示在该方向新建分屏。
public enum DockDropZone: String, Sendable, CaseIterable {
    case center, left, right, top, bottom

    /// 由指针位置判定落点。
    /// - Parameters:
    ///   - point: 组内坐标(左上为原点)
    ///   - size: 组的尺寸
    ///   - edgeFraction: 边缘区占比(默认 0.25)
    public static func zone(at point: CGPoint, in size: CGSize, edgeFraction: Double = 0.25) -> DockDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        let dl = x, dr = 1 - x, dt = y, db = 1 - y
        let nearest = min(dl, dr, dt, db)
        guard nearest < edgeFraction else { return .center }
        if nearest == dl { return .left }
        if nearest == dr { return .right }
        if nearest == dt { return .top }
        return .bottom
    }
}

/// 停靠布局。
public struct DockLayout: Codable, Equatable, Sendable {
    public private(set) var root: DockNode
    public private(set) var focusedGroupID: UUID
    /// 被最大化的组(双击标签切换);仅界面状态,持久化无影响
    public var maximizedGroupID: UUID?

    public init() {
        let group = TabGroup()
        root = .group(group)
        focusedGroupID = group.id
    }

    /// 以给定根节点创建(用于恢复),并立即校正不变量。
    public init(root: DockNode, focusedGroupID: UUID? = nil) {
        self.root = root
        self.focusedGroupID = focusedGroupID ?? UUID()
        sanitize()
    }

    // MARK: 查询

    /// 按从左到右、从上到下排列的所有组。
    public var groups: [TabGroup] { Self.collectGroups(root) }

    /// 所有标签。
    public var allTabs: [WorkbenchTab] { groups.flatMap(\.tabs) }

    public var focusedGroup: TabGroup? { group(focusedGroupID) }

    public func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }

    /// 标签所在的组与下标。
    public func location(of tabID: UUID) -> (group: UUID, index: Int)? {
        for group in groups {
            if let index = group.tabs.firstIndex(where: { $0.id == tabID }) { return (group.id, index) }
        }
        return nil
    }

    /// 查找内容相同的标签。
    public func tab(for kind: TabKind) -> WorkbenchTab? { allTabs.first { $0.kind == kind } }

    public func tab(_ id: UUID) -> WorkbenchTab? { allTabs.first { $0.id == id } }

    // MARK: 打开 / 激活 / 关闭

    /// 打开标签:相同内容已存在则聚焦(并可固化预览、更新标题与行号);否则新建在目标组(默认聚焦组)。
    /// - Parameters:
    ///   - kind: 内容
    ///   - title: 标题
    ///   - preview: 是否以预览方式打开(同组已有预览标签时替换之)
    ///   - groupID: 目标组;为空使用聚焦组
    ///   - line: 要定位的行号
    /// - Returns: 标签 ID
    @discardableResult
    public mutating func open(_ kind: TabKind, title: String, preview: Bool = false, in groupID: UUID? = nil, line: Int? = nil) -> UUID {
        if let existing = tab(for: kind), let loc = location(of: existing.id) {
            update(existing.id) { tab in
                tab.title = title
                if let line { tab.line = line }
                if !preview { tab.isPreview = false }
            }
            focus(group: loc.group, activating: existing.id)
            return existing.id
        }
        let target = groupID.flatMap { group($0) != nil ? $0 : nil } ?? focusedGroupID
        let new = WorkbenchTab(kind: kind, title: title, isPreview: preview, line: line)
        mutateGroup(target) { group in
            if preview, let old = group.tabs.firstIndex(where: { $0.isPreview && !$0.isPinned }) {
                group.tabs[old] = new
            } else {
                group.tabs.append(new)
                Self.keepPinnedFirst(&group)
            }
            group.activeID = new.id
        }
        focusedGroupID = target
        return new.id
    }

    /// 激活标签并聚焦其所在组。
    public mutating func activate(_ tabID: UUID) {
        guard let loc = location(of: tabID) else { return }
        focus(group: loc.group, activating: tabID)
    }

    /// 关闭标签;空组会被折叠。
    public mutating func close(_ tabID: UUID) {
        guard let loc = location(of: tabID) else { return }
        mutateGroup(loc.group) { group in
            let wasActive = group.activeID == tabID
            group.tabs.remove(at: loc.index)
            if wasActive { group.activeID = group.tabs.isEmpty ? nil : group.tabs[min(loc.index, group.tabs.count - 1)].id }
        }
        collapseEmptyGroups()
    }

    /// 关闭组内除指定标签与固定标签外的其它标签。
    public mutating func closeOthers(_ tabID: UUID) {
        guard let loc = location(of: tabID) else { return }
        mutateGroup(loc.group) { group in
            group.tabs.removeAll { $0.id != tabID && !$0.isPinned }
            group.activeID = tabID
        }
    }

    /// 关闭满足条件的全部标签(例如项目被移除时关闭其会话相关标签)。
    public mutating func closeTabs(where predicate: (WorkbenchTab) -> Bool) {
        for tab in allTabs where predicate(tab) { close(tab.id) }
    }

    // MARK: 修改标签属性

    public mutating func setTitle(_ title: String, for tabID: UUID) { update(tabID) { $0.title = title } }

    public mutating func setDirty(_ dirty: Bool, for tabID: UUID) {
        update(tabID) { tab in
            tab.isDirty = dirty
            if dirty { tab.isPreview = false }
        }
    }

    /// 固化预览标签。
    public mutating func keepOpen(_ tabID: UUID) { update(tabID) { $0.isPreview = false } }

    /// 切换固定;固定会同时固化预览并把标签移到组内最前。
    public mutating func togglePinned(_ tabID: UUID) {
        guard let loc = location(of: tabID) else { return }
        mutateGroup(loc.group) { group in
            guard let index = group.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            group.tabs[index].isPinned.toggle()
            if group.tabs[index].isPinned { group.tabs[index].isPreview = false }
            Self.keepPinnedFirst(&group)
        }
    }

    // MARK: 移动与分屏

    /// 把标签移入目标组的指定位置(同组内即重新排序)。
    /// - Parameters:
    ///   - tabID: 被移动的标签
    ///   - groupID: 目标组
    ///   - index: 目标下标(越界则追加)
    public mutating func move(_ tabID: UUID, toGroup groupID: UUID, at index: Int? = nil) {
        guard let loc = location(of: tabID), group(groupID) != nil, let tab = tab(tabID) else { return }
        mutateGroup(loc.group) { group in
            group.tabs.remove(at: loc.index)
            if group.activeID == tabID { group.activeID = group.tabs.isEmpty ? nil : group.tabs[min(loc.index, group.tabs.count - 1)].id }
        }
        mutateGroup(groupID) { group in
            var at = index ?? group.tabs.count
            if loc.group == groupID, at > loc.index { at -= 1 }
            at = min(max(at, 0), group.tabs.count)
            group.tabs.insert(tab, at: at)
            Self.keepPinnedFirst(&group)
            group.activeID = tabID
        }
        focusedGroupID = groupID
        collapseEmptyGroups()
    }

    /// 把标签拖到某组的边缘:在该方向新建分屏并放入标签。落点为 `.center` 时等价于并入该组。
    /// - Parameters:
    ///   - tabID: 被拖动的标签
    ///   - groupID: 目标组
    ///   - zone: 落点
    public mutating func drop(_ tabID: UUID, onGroup groupID: UUID, zone: DockDropZone) {
        guard location(of: tabID) != nil, group(groupID) != nil else { return }
        guard zone != .center else { move(tabID, toGroup: groupID); return }
        // 目标组只剩这一个标签时拖到自己的边缘没有意义
        if let g = group(groupID), g.tabs.count == 1, g.tabs[0].id == tabID { return }
        guard let tab = tab(tabID), let loc = location(of: tabID) else { return }
        mutateGroup(loc.group) { group in
            group.tabs.remove(at: loc.index)
            if group.activeID == tabID { group.activeID = group.tabs.isEmpty ? nil : group.tabs[min(loc.index, group.tabs.count - 1)].id }
        }
        let fresh = TabGroup(tabs: [tab])
        let axis: DockAxis = (zone == .left || zone == .right) ? .horizontal : .vertical
        let before = zone == .left || zone == .top
        root = Self.insert(newGroup: fresh, beside: groupID, axis: axis, before: before, in: root)
        focusedGroupID = fresh.id
        collapseEmptyGroups()
    }

    /// 设置分屏比例(拖动分隔条时调用),自动归一化并限制最小占比。
    public mutating func setRatios(_ ratios: [Double], forSplit splitID: UUID, minimum: Double = 0.1) {
        root = Self.mapSplit(root, id: splitID) { split in
            guard ratios.count == split.children.count else { return }
            split.ratios = Self.normalize(ratios, minimum: minimum)
        }
    }

    /// 聚焦某个组(不改变激活标签)。
    public mutating func focus(group id: UUID) {
        if group(id) != nil { focusedGroupID = id }
    }

    /// 切换组的最大化状态。
    public mutating func toggleMaximize(group id: UUID) {
        maximizedGroupID = maximizedGroupID == id ? nil : (group(id) != nil ? id : nil)
    }

    // MARK: 校正(恢复持久化状态时调用)

    /// 修复损坏/不一致的状态:去重同内容标签、移除空组、校正激活项与分屏比例。
    public mutating func sanitize() {
        var seen = Set<TabKind>()
        root = Self.dedupe(root, seen: &seen)
        collapseEmptyGroups()
        root = Self.fixRatios(root)
        if group(focusedGroupID) == nil { focusedGroupID = groups.first?.id ?? UUID() }
        if let m = maximizedGroupID, group(m) == nil { maximizedGroupID = nil }
        if groups.isEmpty {
            let g = TabGroup()
            root = .group(g)
            focusedGroupID = g.id
        }
    }

    // MARK: 启动恢复

    /// 返回适合启动时恢复的布局:剔除不可恢复的临时标签(子 Agent、预览、终端)与已不存在项目的标签,并校正结构。
    /// - Parameter projectIDs: 当前仍存在的项目 ID
    public func restoredForLaunch(projectIDs: Set<String>) -> DockLayout {
        var copy = self
        copy.maximizedGroupID = nil
        copy.closeTabs { tab in
            switch tab.kind {
            case .subagent, .preview, .terminal, .agentTerminal: return true
            case .chat(let id), .changes(let id), .history(let id, _): return !projectIDs.contains(id)
            case .file(let path), .diff(let path), .blame(let path):
                return !projectIDs.contains { path == $0 || path.hasPrefix($0 + "/") } || !FileManager.default.fileExists(atPath: path)
            }
        }
        copy.sanitize()
        return copy
    }

    // MARK: 内部实现

    private mutating func focus(group id: UUID, activating tabID: UUID) {
        mutateGroup(id) { $0.activeID = tabID }
        focusedGroupID = id
    }

    private mutating func update(_ tabID: UUID, _ change: (inout WorkbenchTab) -> Void) {
        guard let loc = location(of: tabID) else { return }
        mutateGroup(loc.group) { group in
            if let i = group.tabs.firstIndex(where: { $0.id == tabID }) { change(&group.tabs[i]) }
        }
    }

    private mutating func mutateGroup(_ id: UUID, _ change: (inout TabGroup) -> Void) {
        root = Self.mapGroup(root, id: id, change)
    }

    /// 折叠空组:非根的空组被移除;只剩一个子节点的分屏被其子节点替换。
    private mutating func collapseEmptyGroups() {
        root = Self.collapse(root, isRoot: true)
        if group(focusedGroupID) == nil { focusedGroupID = groups.first?.id ?? focusedGroupID }
        if let m = maximizedGroupID, group(m) == nil { maximizedGroupID = nil }
    }

    private static func keepPinnedFirst(_ group: inout TabGroup) {
        let pinned = group.tabs.filter(\.isPinned), rest = group.tabs.filter { !$0.isPinned }
        group.tabs = pinned + rest
    }

    private static func collectGroups(_ node: DockNode) -> [TabGroup] {
        switch node {
        case .group(let g): return [g]
        case .split(let s): return s.children.flatMap(collectGroups)
        }
    }

    private static func mapGroup(_ node: DockNode, id: UUID, _ change: (inout TabGroup) -> Void) -> DockNode {
        switch node {
        case .group(var g):
            if g.id == id { change(&g) }
            return .group(g)
        case .split(var s):
            s.children = s.children.map { mapGroup($0, id: id, change) }
            return .split(s)
        }
    }

    private static func mapSplit(_ node: DockNode, id: UUID, _ change: (inout DockSplit) -> Void) -> DockNode {
        switch node {
        case .group: return node
        case .split(var s):
            if s.id == id { change(&s) }
            s.children = s.children.map { mapSplit($0, id: id, change) }
            return .split(s)
        }
    }

    /// 在目标组旁插入新组:父分屏同轴则并入其子节点列表,否则把目标组替换为新的二分屏。
    private static func insert(newGroup: TabGroup, beside target: UUID, axis: DockAxis, before: Bool, in node: DockNode) -> DockNode {
        switch node {
        case .group(let g):
            guard g.id == target else { return node }
            let pair: [DockNode] = before ? [.group(newGroup), .group(g)] : [.group(g), .group(newGroup)]
            return .split(DockSplit(axis: axis, children: pair))
        case .split(var s):
            if s.axis == axis, let index = s.children.firstIndex(where: { if case .group(let g) = $0 { return g.id == target } else { return false } }) {
                let share = s.ratios[index] / 2
                s.ratios[index] = share
                let at = before ? index : index + 1
                s.children.insert(.group(newGroup), at: at)
                s.ratios.insert(share, at: at)
                return .split(s)
            }
            s.children = s.children.map { insert(newGroup: newGroup, beside: target, axis: axis, before: before, in: $0) }
            return .split(s)
        }
    }

    private static func collapse(_ node: DockNode, isRoot: Bool) -> DockNode {
        switch node {
        case .group: return node
        case .split(var s):
            var kept: [DockNode] = [], ratios: [Double] = []
            for (i, child) in s.children.enumerated() {
                let c = collapse(child, isRoot: false)
                if case .group(let g) = c, g.tabs.isEmpty { continue }
                kept.append(c)
                ratios.append(i < s.ratios.count ? s.ratios[i] : 1)
            }
            if kept.isEmpty { return .group(TabGroup()) }
            if kept.count == 1 { return kept[0] }
            s.children = kept
            s.ratios = normalize(ratios, minimum: 0.05)
            return .split(s)
        }
    }

    private static func dedupe(_ node: DockNode, seen: inout Set<TabKind>) -> DockNode {
        switch node {
        case .group(var g):
            g.tabs = g.tabs.filter { seen.insert($0.kind).inserted }
            if g.activeID == nil || !g.tabs.contains(where: { $0.id == g.activeID }) { g.activeID = g.tabs.first?.id }
            return .group(g)
        case .split(var s):
            s.children = s.children.map { dedupe($0, seen: &seen) }
            return .split(s)
        }
    }

    private static func fixRatios(_ node: DockNode) -> DockNode {
        switch node {
        case .group: return node
        case .split(var s):
            s.children = s.children.map(fixRatios)
            if s.ratios.count != s.children.count || s.ratios.contains(where: { !($0 > 0) || !$0.isFinite }) {
                s.ratios = Array(repeating: 1.0 / Double(max(s.children.count, 1)), count: s.children.count)
            } else {
                s.ratios = normalize(s.ratios, minimum: 0.05)
            }
            return .split(s)
        }
    }

    /// 归一化比例:总和为 1 且每项不小于 minimum(过小的项被抬到 minimum,其余等比缩小)。
    static func normalize(_ values: [Double], minimum: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        let cleaned = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = cleaned.reduce(0, +)
        var result = total > 0 ? cleaned.map { $0 / total } : Array(repeating: 1.0 / Double(values.count), count: values.count)
        let floor = min(minimum, 1.0 / Double(values.count))
        let small = result.indices.filter { result[$0] < floor }
        guard !small.isEmpty else { return result }
        let others = result.indices.filter { !small.contains($0) }
        let otherTotal = others.reduce(0.0) { $0 + result[$1] }
        let budget = 1 - Double(small.count) * floor
        for i in small { result[i] = floor }
        for i in others { result[i] = otherTotal > 0 ? result[i] / otherTotal * budget : budget / Double(others.count) }
        return result
    }
}
