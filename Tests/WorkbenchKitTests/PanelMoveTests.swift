// @author ixxxxoooo
// 面板标签跨区域移动:终端/输出拖到编辑区、侧栏、底部时的模型行为。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("面板标签移动")
struct PanelMoveTests {
    private func makeModel() -> WorkbenchModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-pm-\(UUID().uuidString)/w.json")
        return WorkbenchModel(store: WorkbenchStore(fileURL: url), autoConnect: false) { url in SessionModel(workspace: url) }
    }

    @Test("底部输出标签拖进编辑区:得到输出标签,且可识别为面板")
    func outputToEditor() throws {
        let model = makeModel()
        model.showBottom(.output)
        let id = try #require(model.openPanelTab(.output))
        #expect(model.layout.zone(of: .output) == .editor)
        #expect(model.panelItem(forTab: id) == .output)
    }

    @Test("终端拖进编辑区后再拖回底部:编辑区标签关闭,底部可见且选中终端")
    func terminalRoundTrip() throws {
        let model = makeModel()
        let id = try #require(model.openPanelTab(.terminal))
        #expect(model.panelItem(forTab: id) == .terminal)
        #expect(model.movePanel(.terminal, to: .bottom))
        #expect(model.panelItem(forTab: id) == nil)
        #expect(model.layout.bottomVisible && model.layout.bottomPane == .terminal)
    }

    @Test("拖到右侧栏:面板可见;项目栏类条目不能走终端/输出入口")
    func toSideColumn() {
        let model = makeModel()
        #expect(model.movePanel(.output, to: .right))
        #expect(model.layout.zone(of: .output) == .right && model.layout.outputVisible)
        #expect(model.openPanelTab(.sidebar) == nil)
        #expect(model.movePanel(.sidebar, to: .bottom) == false)
    }

    @Test("拖进编辑区后分屏落点生效")
    func splitDrop() throws {
        let model = makeModel()
        _ = model.dock.open(.file(path: "/tmp/oma-pm.txt"), title: "a")
        let id = try #require(model.openPanelTab(.output))
        let group = try #require(model.dock.focusedGroup?.id)
        model.dock.drop(id, onGroup: group, zone: .right)
        #expect(model.dock.groups.count >= 2)
        #expect(model.panelItem(forTab: id) == .output)
    }

    @Test("终端/输出拖到与工具栏同侧:并入标签条,不另起一列")
    func mergeIntoTools() {
        let model = makeModel()
        model.layout.rightVisible = false
        #expect(model.movePanel(.output, to: .right))
        #expect(model.layout.rightVisible)
        #expect(model.layout.toolsPanel == .output)
        #expect(model.layout.isMergedIntoTools(.output))
        #expect(!model.layout.visibleColumns(on: .right).contains(.output))
        model.hideOutput()
        #expect(!model.layout.outputVisible)
    }
}
