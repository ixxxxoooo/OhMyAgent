// @author ixxxxoooo
// 停靠布局与工作台的集成:选择项目打开会话标签、统一打开入口、关闭联动、持久化与启动恢复。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("工作台标签集成")
struct DockIntegrationTests {
    private func makeModel() throws -> (WorkbenchModel, [String], URL, WorkbenchStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-dock-\(UUID().uuidString)")
        let dirs = try ["a", "b"].map { name -> URL in
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let ids = try dirs.map { try #require(model.openProject($0)) }
        return (model, ids, root, store)
    }

    @Test("浏览器默认在右栏停靠区打开,可移到中栏;工具面板标签可解析")
    func browserOpensInRightDockAndToolsTab() throws {
        let (model, _, _, _) = try makeModel()
        let groups = model.dock.groups.count
        let tab = try #require(model.openBrowser(id: "b1", title: "浏览器"))
        #expect(model.dock.groups.count == groups)
        #expect(model.layout.rightVisible && model.host(of: tab) == .right)
        #expect(model.isBrowserOpen(id: "b1"))
        let moved = try #require(model.moveTab(tab, toHost: .center))
        #expect(model.host(of: moved) == .center)
        #expect(model.isBrowserOpen(id: "b1"))
        let tools = model.openToolsTab(.git, title: "Git")
        #expect(model.rightDock.allTabs.contains { $0.id == tools })
        #expect(WorkbenchModel.toolsPane(fromTab: WorkbenchModel.toolsTabPrefix + "git") == .git)
        #expect(WorkbenchModel.toolsPane(fromTab: "oma-browser:x") == nil)
    }

    @Test("打开项目会创建会话标签,切换项目聚焦对应标签")
    func chatTabsFollowProjects() throws {
        let (model, ids, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.dock.allTabs.count == 2)
        #expect(model.dock.focusedGroup?.active?.kind == .chat(projectID: ids[1], slot: nil))
        model.select(project: ids[0])
        #expect(model.dock.allTabs.count == 2)
        #expect(model.dock.focusedGroup?.active?.kind == .chat(projectID: ids[0], slot: nil))
        model.shutdownAll()
    }

    @Test("激活另一个会话标签会同步当前项目")
    func activatingChatTabSelectsProject() throws {
        let (model, ids, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(model.dock.tab(for: .chat(projectID: ids[0], slot: nil))?.id)
        model.activateTab(first)
        #expect(model.selectedProjectID == ids[0])
        model.shutdownAll()
    }

    @Test("文件与 Diff 打开入口:预览替换、双击固化、去重")
    func openEntries() throws {
        let (model, ids, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ids[0] + "/x.swift", other = ids[0] + "/y.swift"
        let a = model.openFile(path, line: 3)
        model.openFile(other)
        #expect(model.dock.tab(a) == nil)     // 预览被替换
        let b = model.openFile(other, preview: false)
        #expect(model.dock.tab(b)?.isPreview == false)
        #expect(model.openFile(other, line: 9, preview: true) == b)
        #expect(model.dock.tab(b)?.line == 9)
        let d = model.openDiff(path)
        #expect(model.dock.tab(d)?.kind == .diff(path: path))
        model.openChanges(project: ids[0])
        #expect(model.dock.tab(for: .changes(projectID: ids[0])) != nil)
        model.shutdownAll()
    }

    @Test("移除项目会关闭其全部相关标签")
    func removeProjectClosesTabs() throws {
        let (model, ids, root, _) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.openFile(ids[0] + "/x.swift", preview: false)
        model.openChanges(project: ids[0])
        model.removeProject(ids[0])
        #expect(model.dock.allTabs.allSatisfy { !WorkbenchModel.belongs($0.kind, toProject: ids[0]) })
        #expect(model.dock.tab(for: .chat(projectID: ids[1], slot: nil)) != nil)
        model.shutdownAll()
    }

    @Test("布局持久化后启动恢复:临时标签与失效标签被剔除")
    func restoreOnLaunch() throws {
        let (model, ids, root, store) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = ids[0] + "/real.txt"
        try "x".write(toFile: real, atomically: true, encoding: .utf8)
        model.openFile(real, preview: false)
        model.openFile(ids[0] + "/missing.txt", preview: false)
        model.dock.open(.terminal(id: "t1"), title: "终端")
        model.dock.open(.subagent(projectID: ids[0], toolCallID: "tc"), title: "子任务")
        model.saveNow()
        model.shutdownAll()

        let reopened = WorkbenchModel(store: store, autoConnect: false) { SessionModel(workspace: $0) }
        let kinds = reopened.dock.allTabs.map(\.kind)
        #expect(kinds.contains(.file(path: real)))
        #expect(!kinds.contains(.file(path: ids[0] + "/missing.txt")))
        #expect(!kinds.contains(.terminal(id: "t1")))
        #expect(!kinds.contains(.subagent(projectID: ids[0], toolCallID: "tc")))
        #expect(kinds.contains(.chat(projectID: ids[0], slot: nil)))
        reopened.shutdownAll()
    }
}
