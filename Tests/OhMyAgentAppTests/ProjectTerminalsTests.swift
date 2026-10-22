// @author ixxxxoooo
// 项目共享终端表:按项目隔离、去重、移除;IDE 工作区与 Agent 侧读写同一份。

import Foundation
import IDEKit
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("项目共享终端表")
struct ProjectTerminalsTests {
    @Test("按项目隔离、同 id 去重、空 id 忽略、可移除")
    func addAndRemove() {
        let store = ProjectTerminals.shared
        let a = "/tmp/pt-test-a", b = "/tmp/pt-test-b"
        defer { for e in store.entries where e.project?.hasPrefix("/tmp/pt-test-") == true { store.remove(id: e.id) } }
        store.add(id: "t1", title: "终端", project: a)
        store.add(id: "t1", title: "重复", project: a)
        store.add(id: "t2", title: "终端 2", project: b)
        store.add(id: "", title: "空", project: a)
        #expect(store.entries(for: a).map(\.id) == ["t1"])
        #expect(store.entries(for: b).map(\.id) == ["t2"])
        #expect(store.ids.isSuperset(of: ["t1", "t2"]))
        store.remove(id: "t1")
        #expect(store.entries(for: a).isEmpty)
    }

    @Test("IDE 工作区新建/关闭终端写入同一份共享表")
    func workspaceUsesSharedStore() throws {
        let root = NSTemporaryDirectory() + "pt-test-ws-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = IDEWorkspace(model: IDEWindowModel(snapshot: IDEWindowSnapshot(workspaceRoot: root)))
        workspace.newTerminal()
        workspace.newTerminal()
        let ids = workspace.terminalIDs
        #expect(ids.count == 2)
        // Agent 侧用不同写法的同一路径也读到同一份
        #expect(ProjectTerminals.shared.entries(for: root).map(\.id) == ids)
        #expect(workspace.activeTerminalID == ids.last)
        workspace.closeTerminal(ids[1])
        #expect(workspace.terminalIDs == [ids[0]])
        #expect(workspace.activeTerminalID == ids[0])
        workspace.closeAllTerminals()
        #expect(workspace.terminalIDs.isEmpty)
    }
}
