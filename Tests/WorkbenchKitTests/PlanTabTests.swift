// @author ixxxxoooo
// 计划标签标识测试:路径与标签标识互转,不会和画布/浏览器标签混淆。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@Suite("计划标签")
struct PlanTabTests {
    @Test("计划文件路径与标签标识互转")
    func roundTrip() {
        let path = "/Users/demo/.claude/plans/为路由层加入指标_8522af.plan.md"
        let id = WorkbenchModel.planTabPrefix + path
        #expect(WorkbenchModel.planPath(fromTab: id) == path)
        #expect(WorkbenchModel.planPath(fromTab: "oma-canvas:abc") == nil)
        #expect(WorkbenchModel.canvasID(fromTab: id) == nil)
        #expect(WorkbenchModel.browserID(fromTab: id) == nil)
    }

    @MainActor
    @Test("打开计划标签:同一文件复用同一个标签")
    func openReusesTab() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-plan-tab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { SessionModel(workspace: $0) }
        let first = model.openPlan(path: "/tmp/a.plan.md", title: "计划 A")
        let again = model.openPlan(path: "/tmp/a.plan.md", title: "计划 A")
        let other = model.openPlan(path: "/tmp/b.plan.md", title: "计划 B")
        #expect(first == again)
        #expect(other != first)
    }
}
