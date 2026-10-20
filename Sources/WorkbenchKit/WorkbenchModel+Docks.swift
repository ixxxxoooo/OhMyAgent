// @author ixxxxoooo
// 两个停靠区:中栏 `dock`(会话/文件/Diff)与右栏 `rightDock`(终端/输出/预览/Plan/资源管理器等)。
// 本文件提供跨停靠区的统一入口:全局唯一的标签查找、按目标停靠区打开、跨区移动与关闭(无视图,可测试)。

import Foundation

/// 停靠区所在位置。
public enum DockHost: String, Codable, Sendable, CaseIterable {
    /// 中栏(编辑区)
    case center
    /// 右栏
    case right
}

/// 文件、计划等「可预览内容」的打开位置偏好。
public enum OpenTarget: String, Codable, Sendable, CaseIterable {
    /// 按设置项「文件默认打开位置」决定
    case auto
    /// 右栏
    case right
    /// 中栏编辑区
    case editor
}

@MainActor
public extension WorkbenchModel {
    /// 某个停靠区的当前布局。
    /// - Parameter host: 停靠区
    func dock(_ host: DockHost) -> DockLayout {
        host == .center ? dock : rightDock
    }

    /// 修改某个停靠区(经属性观察者落盘、回收会话)。
    /// - Parameters:
    ///   - host: 停靠区
    ///   - body: 修改闭包
    func mutateDock(_ host: DockHost, _ body: (inout DockLayout) -> Void) {
        switch host {
        case .center:
            var copy = dock
            body(&copy)
            if copy != dock { dock = copy }
        case .right:
            var copy = rightDock
            body(&copy)
            if copy != rightDock { rightDock = copy }
        }
    }

    /// 最近获得焦点的停靠区里、聚焦组的激活标签(「当前标签」命令使用)。
    var focusedActiveTab: WorkbenchTab? { dock(focusedHost).focusedGroup?.active }

    /// 设置任一停靠区里标签的「未保存」标记。
    /// - Parameters:
    ///   - dirty: 是否有未保存修改
    ///   - tabID: 标签 ID
    func setDirty(_ dirty: Bool, for tabID: UUID) {
        guard let host = host(of: tabID) else { return }
        mutateDock(host) { $0.setDirty(dirty, for: tabID) }
    }

    /// 在两个停靠区里关闭满足条件的标签。
    /// - Parameter predicate: 判定闭包
    func closeTabsInAllDocks(where predicate: (WorkbenchTab) -> Bool) {
        dock.closeTabs(where: predicate)
        rightDock.closeTabs(where: predicate)
    }

    /// 文件/文件夹被移动后,让两个停靠区里指向旧路径的文件标签改指新路径。
    /// - Parameters:
    ///   - source: 原路径
    ///   - destination: 新路径
    func retargetFilesInAllDocks(from source: String, to destination: String) {
        dock.retargetFiles(from: source, to: destination)
        rightDock.retargetFiles(from: source, to: destination)
    }

    /// 旧布局(底部面板/终端侧栏/工具栏单视图)迁移:可见的终端、输出、工具视图变成右栏停靠区里的标签。启动时调用一次。
    func applyLegacyMigration() {
        guard let migration = layout.legacyMigration else { return }
        layout.legacyMigration = nil
        if let pane = migration.rightPane { showRight(pane) }
        if migration.showTerminal { openTab(.terminal(id: residentTerminalID), title: String(localized: "终端"), host: .right) }
        if migration.showOutput { openTab(.preview(id: Self.outputTabID), title: String(localized: "输出"), host: .right) }
        if migration.showTerminal || migration.showOutput { layout.rightVisible = true }
    }

    /// 把打开位置偏好换算成停靠区(`.auto` 取设置项「文件默认打开位置」)。
    /// - Parameter target: 打开位置偏好
    func resolveHost(_ target: OpenTarget) -> DockHost {
        switch target {
        case .right: return .right
        case .editor: return .center
        case .auto: return layout.fileOpenTarget == .editor ? .center : .right
        }
    }

    /// 移除两个停靠区里某个视图的侧边面板(它被拖成标签时调用,保证同一视图全局只有一处)。
    /// - Parameter pane: 工具视图
    func removeSidePanels(of pane: RightPane) {
        for host in [DockHost.center, .right] {
            for group in dock(host).groups where group.sidePanel?.pane == pane {
                mutateDock(host) { $0.removeSidePanel(in: group.id) }
            }
        }
    }

    /// 与默认打开位置相反的位置(⌥ 单击、右键「在另一侧打开」使用)。
    var oppositeTarget: OpenTarget { resolveHost(.auto) == .right ? .editor : .right }

    /// 两个停靠区里的全部标签(中栏在前)。
    var allDockTabs: [WorkbenchTab] { dock.allTabs + rightDock.allTabs }

    /// 标签所在的停靠区;不存在为 nil。
    /// - Parameter tabID: 标签 ID
    func host(of tabID: UUID) -> DockHost? {
        if dock.location(of: tabID) != nil { return .center }
        if rightDock.location(of: tabID) != nil { return .right }
        return nil
    }

    /// 在两个停靠区里查找内容相同的标签(同一内容全局唯一)。
    /// - Parameter kind: 标签内容
    func existingTab(for kind: TabKind) -> (host: DockHost, tab: WorkbenchTab)? {
        if let tab = dock.tab(for: kind) { return (.center, tab) }
        if let tab = rightDock.tab(for: kind) { return (.right, tab) }
        return nil
    }

    /// 按标签 ID 取标签(两个停靠区都查)。
    /// - Parameter id: 标签 ID
    func anyTab(_ id: UUID) -> WorkbenchTab? {
        dock.tab(id) ?? rightDock.tab(id)
    }

    /// 打开(或聚焦)标签:内容已在任一停靠区打开则就地聚焦,否则放进目标停靠区。
    /// - Parameters:
    ///   - kind: 内容
    ///   - title: 标题
    ///   - preview: 是否预览方式
    ///   - line: 定位行号
    ///   - host: 新建时的目标停靠区
    ///   - groupID: 新建时的目标组(默认该停靠区聚焦组)
    /// - Returns: 标签 ID
    @discardableResult
    func openTab(_ kind: TabKind, title: String, preview: Bool = false, line: Int? = nil, host: DockHost = .center, groupID: UUID? = nil) -> UUID {
        mode = .workspace
        let target = existingTab(for: kind)?.host ?? host
        var result = UUID()
        mutateDock(target) { result = $0.open(kind, title: title, preview: preview, in: groupID, line: line) }
        if target == .right { layout.rightVisible = true }
        return result
    }

    /// 激活任一停靠区里的标签并聚焦其组;会话标签同时切换当前项目。
    /// - Parameter id: 标签 ID
    func activateAnyTab(_ id: UUID) {
        guard let host = host(of: id) else { return }
        mutateDock(host) { $0.activate(id) }
        if host == .right { layout.rightVisible = true }
        syncSelectionFromDock()
    }

    /// 关闭任一停靠区里的标签(记入关闭栈)。
    /// - Parameter id: 标签 ID
    func closeAnyTab(_ id: UUID) {
        guard let host = host(of: id) else { return }
        if host == .center { closeTab(id); return }
        rightDock.close(id)
    }

    /// 把标签移动到另一个(或同一个)停靠区的某个组:落点为中心时并入该组,为边缘时新建分屏。
    /// 同一停靠区内等价于 `DockLayout.move/drop`;跨区时先从原区取出,再以原标签状态插入目标区。
    /// - Parameters:
    ///   - tabID: 标签 ID
    ///   - host: 目标停靠区
    ///   - groupID: 目标组(为空用目标区聚焦组)
    ///   - zone: 落点;nil 表示并入(配合 `index`)
    ///   - index: 并入时的位置
    /// - Returns: 移动后的标签 ID(跨区时会换新 ID);失败为 nil
    @discardableResult
    func moveTab(_ tabID: UUID, toHost host: DockHost, group groupID: UUID? = nil, zone: DockDropZone? = nil, index: Int? = nil) -> UUID? {
        guard let source = self.host(of: tabID), let tab = dock(source).tab(tabID) else { return nil }
        let target = groupID.flatMap { dock(host).group($0) != nil ? $0 : nil } ?? dock(host).focusedGroupID
        if source == host {
            mutateDock(host) { layout in
                if let zone, zone != .center { layout.drop(tabID, onGroup: target, zone: zone) } else { layout.move(tabID, toGroup: target, at: index) }
            }
            return tabID
        }
        // 跨区:先在目标区以相同内容、标题、状态新建,再关闭原区标签(顺序不可颠倒:会话标签关闭瞬间若无承载会被回收)
        var newID = tab.id
        mutateDock(host) { layout in
            newID = layout.open(tab.kind, title: tab.title, preview: tab.isPreview, in: target, line: tab.line)
            if tab.isPinned { layout.togglePinned(newID) }
            if tab.isDirty { layout.setDirty(true, for: newID) }
            if let zone, zone != .center { layout.drop(newID, onGroup: target, zone: zone) } else if let index { layout.move(newID, toGroup: target, at: index) }
        }
        mutateDock(source) { $0.close(tabID) }
        if host == .right { self.layout.rightVisible = true }
        syncSelectionFromDock()
        return newID
    }
}
