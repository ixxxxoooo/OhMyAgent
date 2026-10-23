// @author ixxxxoooo
// 侧栏「会话模式 / 代码模式」各自的工作区记忆:切走时记下当时的项目与活动标签,切回时原样还原。
// 会话模式回到之前打开的那个会话,代码模式回到原来所在的文件(文件树的展开/滚动由侧栏视图常驻保留)。

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

extension WorkbenchModel {
    /// 切换侧栏模式并还原目标模式上次离开时的工作区位置。
    /// - Parameter pane: 目标模式(`LeftPane.available` 之外或与当前相同时忽略)
    public func switchLeftPane(_ pane: LeftPane) {
        guard LeftPane.available.contains(pane), pane != layout.leftPane else { return }
        paneMemory[layout.leftPane] = PaneMemory(projectID: selectedProjectID, tabID: focusedActiveTab?.id)
        layout.leftPane = pane
        if let memory = paneMemory[pane] {
            if let tabID = memory.tabID, anyTab(tabID) != nil {
                activateTab(tabID)
            } else if let projectID = memory.projectID, projects.contains(where: { $0.id == projectID }) {
                select(project: projectID)
            }
        } else if pane == .files, let tab = allDockTabs.last(where: { if case .file = $0.kind { return true } else { return false } }) {
            // 第一次进入代码模式:回到最近打开的文件(没有就保持现状)
            activateTab(tab.id)
        }
    }
}
