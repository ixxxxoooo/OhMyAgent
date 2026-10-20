// @author ixxxxoooo
// 右栏停靠区:跨停靠区的唯一性、打开位置路由、跨区移动与持久化兼容。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("右栏停靠区")
struct RightDockTests {
    private func makeModel(file: URL? = nil) -> (WorkbenchModel, URL) {
        let url = file ?? FileManager.default.temporaryDirectory.appendingPathComponent("oma-rd-\(UUID().uuidString)/w.json")
        let model = WorkbenchModel(store: WorkbenchStore(fileURL: url), autoConnect: false) { url in SessionModel(workspace: url) }
        return (model, url)
    }

    @Test("按目标停靠区打开:右栏打开文件,中栏不出现,右栏自动显示")
    func openInRight() {
        let (model, _) = makeModel()
        let id = model.openFile("/tmp/a.swift", preview: false, target: .right)
        #expect(model.host(of: id) == .right)
        #expect(model.dock.allTabs.contains { $0.id == id } == false)
        #expect(model.layout.rightVisible)
    }

    @Test("同一内容全局唯一:已在右栏打开,再以编辑区为目标打开只聚焦原标签")
    func uniqueAcrossDocks() {
        let (model, _) = makeModel()
        let first = model.openFile("/tmp/a.swift", preview: false, target: .right)
        let second = model.openFile("/tmp/a.swift", preview: false, target: .editor)
        #expect(first == second)
        #expect(model.allDockTabs.filter { $0.kind == .file(path: "/tmp/a.swift") }.count == 1)
    }

    @Test("设置项决定默认位置:auto 跟随 fileOpenTarget")
    func autoFollowsSetting() {
        let (model, _) = makeModel()
        model.layout.fileOpenTarget = .right
        let right = model.openFile("/tmp/r.swift", preview: false)
        #expect(model.host(of: right) == .right)
        model.layout.fileOpenTarget = .editor
        let center = model.openFile("/tmp/c.swift", preview: false)
        #expect(model.host(of: center) == .center)
    }

    @Test("跨区移动:右栏标签拖进中栏,原区关闭、内容保留")
    func moveAcrossDocks() throws {
        let (model, _) = makeModel()
        let id = model.openFile("/tmp/a.swift", preview: false, target: .right)
        let moved = try #require(model.moveTab(id, toHost: .center))
        #expect(model.host(of: moved) == .center)
        #expect(model.rightDock.allTabs.isEmpty)
        #expect(model.dock.tab(moved)?.kind == .file(path: "/tmp/a.swift"))
    }

    @Test("跨区拖到边缘:在目标区新建分屏")
    func moveAcrossWithSplit() throws {
        let (model, _) = makeModel()
        let a = model.openFile("/tmp/a.swift", preview: false, target: .right)
        let b = model.openFile("/tmp/b.swift", preview: false, target: .editor)
        let group = try #require(model.rightDock.location(of: a)?.group)
        let moved = try #require(model.moveTab(b, toHost: .right, group: group, zone: .bottom))
        #expect(model.rightDock.groups.count == 2)
        #expect(model.host(of: moved) == .right)
    }

    @Test("会话标签跨区移动不会被回收")
    func chatSurvivesMove() throws {
        let (model, _) = makeModel()
        let tab = model.dock.open(.chat(projectID: "/tmp", slot: "s1"), title: "chat")
        let moved = try #require(model.moveTab(tab, toHost: .right))
        #expect(model.host(of: moved) == .right)
    }

    @Test("右栏停靠布局随状态落盘并还原(终端/输出/工具面板保留)")
    func persistence() throws {
        let (model, url) = makeModel()
        model.openTab(.preview(id: WorkbenchModel.outputTabID), title: "输出", host: .right)
        model.openTab(.preview(id: WorkbenchModel.toolsTabPrefix + "files"), title: "文件", host: .right)
        model.saveInBackground()
        // 等待后台落盘
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: url.path) { Thread.sleep(forTimeInterval: 0.05) }
        let (restored, _) = makeModel(file: url)
        #expect(restored.rightDock.allTabs.map(\.kind).contains(.preview(id: WorkbenchModel.outputTabID)))
        #expect(restored.rightDock.allTabs.map(\.kind).contains(.preview(id: WorkbenchModel.toolsTabPrefix + "files")))
    }

    @Test("旧状态文件没有 rightDock:读取为空布局")
    func legacyStateWithoutRightDock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-rd-\(UUID().uuidString)/w.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"layout\":{},\"projects\":[]}".utf8).write(to: url)
        let (model, _) = makeModel(file: url)
        #expect(model.rightDock.allTabs.isEmpty)
    }

    @Test("关闭右栏标签后不再存在;closeAnyTab 同时支持两个区")
    func closeAny() {
        let (model, _) = makeModel()
        let id = model.openFile("/tmp/a.swift", preview: false, target: .right)
        model.closeAnyTab(id)
        #expect(model.host(of: id) == nil)
    }
}
