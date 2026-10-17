// @author ixxxxoooo
// 项目切换器:项目列表合并、当前项目匹配与模糊过滤测试。

import Foundation
import Testing
import WorkbenchKit

@testable import OhMyAgentApp

@Suite("项目切换列表逻辑")
struct ProjectSwitcherTests {
    private func entry(_ name: String, path: String) -> ProjectEntry {
        var p = ProjectEntry(url: URL(fileURLWithPath: path))
        p.name = name
        return p
    }

    @Test("工作台项目与最近项目合并与去重")
    func itemMerging() {
        let projects = [
            entry("OhMyAgent", path: "/work/OhMyAgent"),
            entry("kuku", path: "/work/kuku")
        ]
        let recents = [
            "/work/kuku", // 重复,应去重
            "/work/super-x"
        ]

        let items = ProjectSwitcherListing.items(
            workspaceProjects: projects,
            recentPaths: recents,
            currentWorkspace: URL(fileURLWithPath: "/work/OhMyAgent"),
            isChatArea: false,
            fileExists: { _ in true }
        )

        #expect(items.count == 3)
        #expect(items[0].name == "OhMyAgent")
        #expect(items[0].isCurrent == true)
        #expect(items[1].name == "kuku")
        #expect(items[1].isCurrent == false)
        #expect(items[2].name == "super-x")
        #expect(items[2].isCurrent == false)
    }

    @Test("会话区模式下所有项目均非当前项目")
    func chatAreaSelection() {
        let projects = [entry("OhMyAgent", path: "/work/OhMyAgent")]
        let items = ProjectSwitcherListing.items(
            workspaceProjects: projects,
            recentPaths: [],
            currentWorkspace: URL(fileURLWithPath: "/work/OhMyAgent"),
            isChatArea: true
        )

        #expect(items.count == 1)
        #expect(items[0].isCurrent == false)
    }

    @Test("按关键字过滤项目")
    func queryFiltering() {
        let items = [
            ProjectPickItem(id: "1", name: "OhMyAgent", isCurrent: true, icon: "folder"),
            ProjectPickItem(id: "2", name: "kuku", isCurrent: false, icon: "folder"),
            ProjectPickItem(id: "3", name: "data-viewer", isCurrent: false, icon: "folder")
        ]

        #expect(ProjectSwitcherListing.filter(items, query: "").count == 3)
        #expect(ProjectSwitcherListing.filter(items, query: "agent").map(\.name) == ["OhMyAgent"])
        #expect(ProjectSwitcherListing.filter(items, query: "data").map(\.name) == ["data-viewer"])
        #expect(ProjectSwitcherListing.filter(items, query: "nonexistent").isEmpty)
    }
}
