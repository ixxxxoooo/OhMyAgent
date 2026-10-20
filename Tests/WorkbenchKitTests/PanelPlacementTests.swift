// @author ixxxxoooo
// 面板摆放测试:布局持久化与旧文件兼容(含底部/终端侧栏迁移到右栏标签)、列的归属与可见性、拖动落点几何。

import CoreGraphics
import Foundation
import Testing
@testable import ChatKit
@testable import WorkbenchKit

@Suite("面板摆放模型")
struct PanelPlacementModelTests {
    @Test("默认摆放:项目栏在左,右栏停靠区在右")
    func defaults() {
        let layout = WorkbenchLayout()
        #expect(layout.columns(on: .left) == [.sidebar])
        #expect(layout.columns(on: .right) == [.tools])
        #expect(layout.visibleColumns(on: .right).isEmpty)
        #expect(layout.toggleCount(on: .left) == 1 && layout.toggleCount(on: .right) == 1)
    }

    @Test("同侧两列由外向内排序:项目栏、右栏停靠区")
    func columnOrdering() {
        var layout = WorkbenchLayout()
        layout.placement = PanelPlacement(sidebarSide: .left, toolsSide: .left)
        layout.rightVisible = true
        #expect(layout.columns(on: .left) == [.sidebar, .tools])
        #expect(layout.visibleColumns(on: .left) == [.sidebar, .tools])
        #expect(layout.columns(on: .right).isEmpty)
        #expect(layout.toggleCount(on: .left) == 2)
    }

    @Test("旧版本状态文件(底部终端 + 右栏 Git)可解码,并产生迁移信息")
    func legacyDecoding() throws {
        let json = #"{"leftVisible":false,"rightVisible":true,"bottomVisible":true,"leftWidth":300,"rightWidth":400,"bottomHeight":200,"leftPane":"sessions","rightPane":"git","bottomPane":"terminal"}"#
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: Data(json.utf8))
        #expect(layout.placement == PanelPlacement())
        #expect(layout.leftWidth == 300)
        let migration = layout.legacyMigration
        #expect(migration?.showTerminal == true && migration?.rightPane == .git && migration?.showOutput == false)
    }

    @Test("旧版本终端放在编辑区时不迁移到右栏")
    func legacyEditorTerminalNotMigrated() throws {
        let json = #"{"bottomVisible":true,"bottomPane":"terminal","placement":{"terminal":"editor","output":"bottom"}}"#
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: Data(json.utf8))
        #expect(layout.legacyMigration == nil)
    }

    @Test("新格式状态文件不产生迁移信息")
    func newFormatNoMigration() throws {
        let data = try JSONEncoder().encode(WorkbenchLayout())
        #expect(try JSONDecoder().decode(WorkbenchLayout.self, from: data).legacyMigration == nil)
    }

    @Test("终端列表宽度与折叠状态可往返,并被限制在范围内")
    func terminalListLayout() throws {
        var layout = WorkbenchLayout()
        layout.terminalListWidth = 240
        layout.terminalListCollapsed = true
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(WorkbenchLayout.self, from: data) == layout)
        layout.terminalListWidth = 9999
        layout.clamp()
        #expect(layout.terminalListWidth == PanelMetrics.terminalListRange.upperBound)
        layout.terminalListWidth = 1
        layout.clamp()
        #expect(layout.terminalListWidth == PanelMetrics.terminalListRange.lowerBound)
    }

    @Test("未知的摆放取值回落到默认值,不会让整个状态文件失效")
    func unknownValues() throws {
        let json = #"{"placement":{"sidebarSide":"up"}}"#
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: Data(json.utf8))
        #expect(layout.placement == PanelPlacement())
    }

    @Test("摆放配置编码后可原样解码")
    func roundTrip() throws {
        var layout = WorkbenchLayout()
        layout.placement = PanelPlacement(sidebarSide: .right, toolsSide: .left)
        layout.rightWidth = 555
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(WorkbenchLayout.self, from: data) == layout)
    }

    @Test("通用分隔条换算:左侧列向右拖变宽,右侧列向左拖变宽,并限制在范围内")
    func resizing() {
        let range = PanelMetrics.leftRange
        #expect(PanelMetrics.resized(base: 300, translation: 20, side: .left, range: range) == 320)
        #expect(PanelMetrics.resized(base: 300, translation: 20, side: .right, range: range) == 280)
        #expect(PanelMetrics.resized(base: 300, translation: -9000, side: .left, range: range) == range.lowerBound)
        #expect(PanelMetrics.resized(base: 300, translation: -9000, side: .right, range: range) == range.upperBound)
    }
}

@Suite("面板拖动落点")
struct PanelDropTargetTests {
    private let size = CGSize(width: 1000, height: 800)

    @Test("按左右半幅映射到对应区域")
    func zones() {
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: 50, y: 400), in: size) == .left)
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: 950, y: 400), in: size) == .right)
        #expect(PanelItem.sidebar.dropTarget(at: CGPoint(x: 499, y: 10), in: size) == .left)
    }

    @Test("指针在工作区之外时取消")
    func outside() {
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: -5, y: 100), in: size) == nil)
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: 500, y: 900), in: size) == nil)
        #expect(PanelItem.tools.dropTarget(at: CGPoint(x: 5, y: 5), in: .zero) == nil)
    }

    @Test("高亮区域落在工作区内")
    func highlight() {
        for zone in PanelZone.allCases {
            #expect(CGRect(origin: .zero, size: size).contains(zone.highlight(in: size)))
        }
        let left = PanelZone.left.highlight(in: size)
        #expect(left.minX == 0 && left.width == 250 && left.height == 800)
    }
}
