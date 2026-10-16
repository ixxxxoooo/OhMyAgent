// @author ixxxxoooo
// 面板拖拽摆放:输出面板可去四个区域,项目栏/工具栏只能在左右,拖拽载荷往返,旧状态不受影响。

import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("面板拖拽摆放")
struct PanelDragPlacementTests {
    private func makeModel() -> WorkbenchModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-pd-\(UUID().uuidString)/w.json")
        return WorkbenchModel(store: WorkbenchStore(fileURL: url), autoConnect: false) { url in SessionModel(workspace: url) }
    }

    @Test("拖拽载荷往返,非法载荷被拒绝")
    func payloadRoundTrip() {
        for item in PanelItem.allCases { #expect(PanelItem.parse(payload: item.payload) == item) }
        #expect(PanelItem.parse(payload: "hello") == nil)
        #expect(PanelItem.parse(payload: "oma-panel:unknown") == nil)
    }

    @Test("项目栏与工具栏不能放到底部或编辑区")
    func sidebarOnlySides() {
        let model = makeModel()
        #expect(model.place(.sidebar, in: .bottom) == false)
        #expect(model.place(.tools, in: .editor) == false)
        #expect(model.place(.sidebar, in: .right))
        #expect(model.layout.zone(of: .sidebar) == .right)
    }

    @Test("输出面板可放到每个区域,并出现在对应区域列表里")
    func outputAnywhere() {
        let model = makeModel()
        for zone in PanelZone.allCases {
            #expect(model.place(.output, in: zone))
            #expect(model.layout.zone(of: .output) == zone)
            #expect(model.layout.items(in: zone).contains(.output))
        }
    }

    @Test("终端与输出摆放到不同区域互不影响")
    func independentPlacement() {
        let model = makeModel()
        _ = model.place(.terminal, in: .right)
        _ = model.place(.output, in: .editor)
        #expect(model.layout.zone(of: .terminal) == .right)
        #expect(model.layout.zone(of: .output) == .editor)
    }
}
