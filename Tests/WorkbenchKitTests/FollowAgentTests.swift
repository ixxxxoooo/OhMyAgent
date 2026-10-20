// @author ixxxxoooo
// 「跟随 Agent」:Agent 编辑文件后按开关在预览标签中打开并定位。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("跟随 Agent")
struct FollowAgentTests {
    private func makeModel() throws -> (WorkbenchModel, [String], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-follow-\(UUID().uuidString)")
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
        model.layout.fileOpenTarget = .editor  // 本组用例验证中栏标签;右栏路由见 DockIntegrationTests
        let ids = try dirs.map { try #require(model.openProject($0)) }
        return (model, ids, root)
    }

    @Test("开关关闭时不打开文件")
    func disabled() throws {
        let (model, ids, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.followAgentEnabled = { false }
        model.followAgentEdit(AgentEdit(path: ids[1] + "/x.swift", firstChangedLine: 5), project: ids[1])
        #expect(model.dock.allTabs.count == 2)
        model.shutdownAll()
    }

    @Test("开关开启:在预览标签中打开并定位到首个改动行;连续编辑复用预览标签")
    func enabled() throws {
        let (model, ids, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.followAgentEnabled = { true }
        let path = ids[1] + "/x.swift"
        model.followAgentEdit(AgentEdit(path: path, firstChangedLine: 5), project: ids[1])
        let tab = try #require(model.dock.tab(for: .file(path: path)))
        #expect(tab.isPreview)
        #expect(tab.line == 5)
        model.followAgentEdit(AgentEdit(path: ids[1] + "/y.swift", firstChangedLine: nil), project: ids[1])
        #expect(model.dock.tab(for: .file(path: path)) == nil)
        #expect(model.dock.allTabs.count == 3)
        model.shutdownAll()
    }

    @Test("只跟随当前选中的项目")
    func onlySelectedProject() throws {
        let (model, ids, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.followAgentEnabled = { true }
        #expect(model.selectedProjectID == ids[1])
        model.followAgentEdit(AgentEdit(path: ids[0] + "/x.swift", firstChangedLine: 1), project: ids[0])
        #expect(model.dock.allTabs.count == 2)
        model.shutdownAll()
    }
}
