// @author ixxxxoooo
// 面板拖拽摆放:项目栏/工具栏只能在左右两侧,拖拽载荷往返,旧状态不受影响。

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

    @Test("项目栏与工具栏只能在左右两侧,放置后位置更新")
    func sidebarOnlySides() {
        let model = makeModel()
        #expect(model.place(.sidebar, in: .right))
        #expect(model.layout.zone(of: .sidebar) == .right)
        #expect(model.place(.tools, in: .left))
        #expect(model.layout.zone(of: .tools) == .left)
    }

    @Test("拖动落点:按左右半幅判定,越界取消")
    func dropTargetPerPanel() {
        let size = CGSize(width: 1000, height: 800)
        for item in PanelItem.allCases {
            #expect(item.dropTarget(at: CGPoint(x: 100, y: 700), in: size) == .left)
            #expect(item.dropTarget(at: CGPoint(x: 600, y: 400), in: size) == .right)
        }
        #expect(PanelItem.sidebar.dropTarget(at: CGPoint(x: -1, y: 10), in: size) == nil)
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: 10, y: 10), in: .zero) == nil)
    }

    @Test("互相换位:项目栏与工具栏可以换到同一侧,并按固定顺序同侧排列")
    func sameSideStacking() {
        let model = makeModel()
        #expect(model.place(.tools, in: .left))
        #expect(model.layout.items(in: .left) == [.sidebar, .tools])
    }
}
