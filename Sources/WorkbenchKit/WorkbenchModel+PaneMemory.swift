// @author ixxxxoooo
// 侧栏「会话模式 / 代码模式」:会话模式显示不绑定项目的通用会话,代码模式显示工作区(项目及其会话)。
// 各自记住离开时的项目与活动标签,切回时原样还原:会话模式回到之前的会话,代码模式回到原来所在的项目与标签。

import Foundation

/// 某个侧栏模式离开时的工作区位置。
public struct PaneMemory: Equatable, Sendable {
    /// 离开时选中的项目
    public var projectID: String?
    /// 离开时聚焦的活动标签
    public var tabID: UUID?

    public init(projectID: String? = nil, tabID: UUID? = nil) {
        self.projectID = projectID
        self.tabID = tabID
    }
}

/// 一个侧栏模式自己的停靠区与右栏显隐:会话模式与代码模式各有一套独立的标签系统。
public struct PaneDocks: Codable, Equatable, Sendable {
    /// 中栏停靠区
    public var dock: DockLayout
    /// 右栏停靠区
    public var rightDock: DockLayout
    /// 右栏是否展开
    public var rightVisible: Bool

    public init(dock: DockLayout = DockLayout(), rightDock: DockLayout = DockLayout(), rightVisible: Bool = false) {
        self.dock = dock
        self.rightDock = rightDock
        self.rightVisible = rightVisible
    }
}

extension WorkbenchModel {
    /// 切换前台侧栏模式:把当前停靠区存起来,换上目标模式自己的停靠区。
    /// 会话模式不显示右栏,进入时收起;代码模式恢复离开时的右栏显隐。
    /// - Parameter pane: 目标模式(与当前相同时忽略)
    func setLeftPane(_ pane: LeftPane) {
        guard pane != layout.leftPane else { return }
        let current = PaneDocks(dock: dock, rightDock: rightDock, rightVisible: layout.rightVisible)
        let next = otherDocks ?? PaneDocks()
        // 先登记待换出的停靠区,再赋值(赋值会触发会话回收,不能误回收后台模式里的会话)
        otherDocks = current
        dock = next.dock
        rightDock = next.rightDock
        layout.leftPane = pane
        layout.rightVisible = pane == .sessions ? false : next.rightVisible
    }

    /// 切换侧栏模式并还原目标模式上次离开时的工作区位置。
    /// - Parameter pane: 目标模式(`LeftPane.available` 之外或与当前相同时忽略)
    public func switchLeftPane(_ pane: LeftPane) {
        guard LeftPane.available.contains(pane), pane != layout.leftPane else { return }
        paneMemory[layout.leftPane] = PaneMemory(projectID: selectedProjectID, tabID: focusedActiveTab?.id)
        setLeftPane(pane)
        if let memory = paneMemory[pane] {
            // 先恢复项目(文件等标签不会改变选中项目),再激活当时聚焦的标签
            let restoredProject = memory.projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
            if let projectID = restoredProject, projectID != selectedProjectID { select(project: projectID) }
            if let tabID = memory.tabID, anyTab(tabID) != nil {
                activateTab(tabID)
                return
            }
            if restoredProject != nil { return }
        } else if let tab = focusedActiveTab, case .chat(let projectID, _) = tab.kind, projects.contains(where: { $0.id == projectID }) {
            // 重启后没有内存记录:回到这个模式自己停靠区里聚焦的会话
            select(project: projectID)
            activateTab(tab.id)
            return
        }
        // 第一次进入该模式(或记住的位置已不存在):落到该模式下最合适的位置
        switch pane {
        case .workspaces:
            if let project = orderedProjects.first(where: { !$0.isChatArea }) { select(project: project.id) }
        default:
            if let chat = chatAreaID ?? ensureChatArea() { select(project: chat) }
        }
    }

    /// 让侧栏模式跟随当前选中的项目:选中会话区 → 会话模式,选中真实项目 → 代码模式
    /// (从搜索、通知等入口跳转时,侧栏随之切到对应模式)。
    public func syncLeftPaneToSelection() {
        guard let entry = selectedEntry else { return }
        let target: LeftPane = entry.isChatArea ? .sessions : .workspaces
        if LeftPane.available.contains(target) { setLeftPane(target) }
    }
}
