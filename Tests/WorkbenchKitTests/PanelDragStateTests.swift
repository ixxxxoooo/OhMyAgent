// @author ixxxxoooo
// 面板拖动临时尺寸测试:拖动中不写布局、结束才提交、范围钳制、分屏比例变化不触发会话回收。

import ACPKit
import AgentHost
import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("面板拖动临时尺寸")
struct PanelDragStateTests {
    @Test("拖动中只有临时值,布局保持不变;有效值优先取临时值")
    func updateDoesNotTouchLayout() {
        let state = PanelDragState()
        let layout = WorkbenchLayout()
        state.update(300, for: .leftWidth)
        #expect(state.value(of: .leftWidth) == 300)
        #expect(state.effective(.leftWidth, committed: layout) == 300)
        #expect(layout.leftWidth == PanelMetrics.leftDefault)
        #expect(state.isDragging)
        // 其他维度不受影响
        #expect(state.value(of: .rightWidth) == nil)
        #expect(state.effective(.rightWidth, committed: layout) == layout.rightWidth)
    }

    @Test("结束时提交一次并清除临时状态")
    func commitWritesLayoutAndClears() {
        let state = PanelDragState()
        var layout = WorkbenchLayout()
        state.update(333, for: .bottomHeight)
        #expect(state.commit(.bottomHeight, to: &layout))
        #expect(layout.bottomHeight == 333)
        #expect(state.value(of: .bottomHeight) == nil)
        #expect(!state.isDragging)
    }

    @Test("临时值与已提交值相同:提交不改变布局")
    func commitNoChange() {
        let state = PanelDragState()
        var layout = WorkbenchLayout()
        state.update(layout.leftWidth, for: .leftWidth)
        #expect(!state.commit(.leftWidth, to: &layout))
        #expect(!state.isDragging)
        // 没有拖动过的维度提交也是空操作
        #expect(!state.commit(.rightWidth, to: &layout))
    }

    @Test("范围钳制:越界与非有限值")
    func clamping() {
        let state = PanelDragState()
        state.update(10, for: .leftWidth)
        #expect(state.value(of: .leftWidth) == PanelMetrics.leftRange.lowerBound)
        state.update(99_999, for: .leftWidth)
        #expect(state.value(of: .leftWidth) == PanelMetrics.leftRange.upperBound)
        state.update(.nan, for: .terminalWidth)
        #expect(state.value(of: .terminalWidth) == PanelMetrics.terminalRange.lowerBound)
        state.update(5, for: .bottomHeight)
        #expect(state.value(of: .bottomHeight) == 120)
        state.update(5_000, for: .bottomHeight)
        #expect(state.value(of: .bottomHeight) == 600)
        state.update(1, for: .terminalListWidth)
        #expect(state.value(of: .terminalListWidth) == PanelMetrics.terminalListRange.lowerBound)
    }

    @Test("取消:清除临时值且不写布局")
    func cancelDiscards() {
        let state = PanelDragState()
        var layout = WorkbenchLayout()
        state.update(400, for: .rightWidth)
        state.cancel(.rightWidth)
        #expect(state.value(of: .rightWidth) == nil)
        #expect(!state.isDragging)
        #expect(!state.commit(.rightWidth, to: &layout))
        #expect(layout.rightWidth == PanelMetrics.rightDefault)
    }

    @Test("面板列到维度的映射与布局读写一致")
    func columnMapping() {
        var layout = WorkbenchLayout()
        for column in PanelColumn.allCases {
            let dimension = PanelDimension(column: column)
            dimension.write(dimension.range.upperBound, to: &layout)
            #expect(layout.width(of: column) == dimension.range.upperBound)
            #expect(dimension.committed(in: layout) == dimension.range.upperBound)
        }
    }

    @Test("模型:拖动中不写 layout,松手一次提交;设置入口钳制范围")
    func modelCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let before = model.layout
        model.panelDrag.update(310, for: .leftWidth)
        model.panelDrag.update(320, for: .leftWidth)
        #expect(model.layout == before, "拖动中不得写 layout")
        model.commitPanelDrag(.leftWidth)
        #expect(model.layout.leftWidth == 320)
        #expect(model.panelDrag.value(of: .leftWidth) == nil)
        model.setPanelDimension(.leftWidth, to: 99_999)
        #expect(model.layout.leftWidth == PanelMetrics.leftRange.upperBound)
        model.setPanelDimension(.leftWidth, to: PanelMetrics.leftDefault)
        #expect(model.layout.leftWidth == PanelMetrics.leftDefault)
    }

    @Test("分屏比例变化:只改比例判为 true,结构或聚焦变化判为 false")
    func differsOnlyInRatios() {
        var dock = DockLayout()
        let a = TabGroup(tabs: [WorkbenchTab(kind: .file(path: "/tmp/a"), title: "a")])
        let b = TabGroup(tabs: [WorkbenchTab(kind: .file(path: "/tmp/b"), title: "b")])
        let split = DockSplit(axis: .horizontal, children: [.group(a), .group(b)])
        dock = DockLayout(root: .split(split), focusedGroupID: a.id)
        var changed = dock
        changed.setRatios([0.3, 0.7], forSplit: split.id)
        #expect(changed != dock)
        #expect(changed.differsOnlyInRatios(from: dock))
        #expect(dock.differsOnlyInRatios(from: dock))
        var focused = dock
        focused.focus(group: b.id)
        #expect(!focused.differsOnlyInRatios(from: dock))
        var closed = dock
        closed.setRatios([0.5, 0.5], forSplit: split.id)
        let single = DockLayout(root: .group(a), focusedGroupID: a.id)
        #expect(!single.differsOnlyInRatios(from: dock))
        #expect(closed.differsOnlyInRatios(from: dock))
    }

    @Test("归一化比例与 setRatios 规则一致")
    func normalizedRatiosMatchSetRatios() {
        let a = TabGroup(tabs: [WorkbenchTab(kind: .file(path: "/tmp/a"), title: "a")])
        let b = TabGroup(tabs: [WorkbenchTab(kind: .file(path: "/tmp/b"), title: "b")])
        let split = DockSplit(axis: .vertical, children: [.group(a), .group(b)])
        var dock = DockLayout(root: .split(split), focusedGroupID: a.id)
        let raw = [0.02, 1.4]
        dock.setRatios(raw, forSplit: split.id)
        guard case .split(let result) = dock.root else { Issue.record("根节点应为分屏"); return }
        #expect(result.ratios == DockLayout.normalizedRatios(raw))
        #expect(abs(result.ratios.reduce(0, +) - 1) < 1e-9)
    }
}
