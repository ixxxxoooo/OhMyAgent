// @author ixxxxoooo
// 面板摆放测试:布局持久化与旧文件兼容、列的归属与可见性、终端迁移、拖动落点几何。

import CoreGraphics
import Foundation
import Testing
@testable import ChatKit
@testable import WorkbenchKit

@Suite("面板摆放模型")
struct PanelPlacementModelTests {
    @Test("默认摆放:项目栏在左,工具栏在右,终端在底部")
    func defaults() {
        let layout = WorkbenchLayout()
        #expect(layout.placement.terminal == .bottom)
        #expect(layout.columns(on: .left) == [.sidebar])
        #expect(layout.columns(on: .right) == [.tools])
        #expect(layout.visibleColumns(on: .right).isEmpty)
        #expect(layout.toggleCount(on: .left) == 1 && layout.toggleCount(on: .right) == 1)
    }

    @Test("同侧多列由外向内排序,终端侧栏只在左/右位置出现")
    func columnOrdering() {
        var layout = WorkbenchLayout()
        layout.placement = PanelPlacement(terminal: .left, sidebarSide: .left, toolsSide: .left)
        layout.rightVisible = true
        layout.terminalVisible = true
        #expect(layout.columns(on: .left) == [.sidebar, .tools, .terminal])
        #expect(layout.visibleColumns(on: .left) == [.sidebar, .tools, .terminal])
        #expect(layout.columns(on: .right).isEmpty)
        #expect(layout.toggleCount(on: .left) == 2)

        layout.placement.terminal = .editor
        #expect(layout.columns(on: .left) == [.sidebar, .tools])
        #expect(!layout.isVisible(.terminal))
    }

    @Test("旧版本状态文件(没有摆放字段)可解码并使用默认摆放")
    func legacyDecoding() throws {
        let json = #"{"leftVisible":false,"rightVisible":true,"bottomVisible":true,"leftWidth":300,"rightWidth":400,"bottomHeight":200,"leftPane":"sessions","rightPane":"git","bottomPane":"terminal"}"#
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: Data(json.utf8))
        #expect(layout.placement == PanelPlacement())
        #expect(layout.leftWidth == 300 && layout.rightPane == .git && layout.bottomPane == .terminal)
        #expect(layout.terminalWidth == PanelMetrics.terminalDefault)
    }

    @Test("未知的摆放取值回落到默认值,不会让整个状态文件失效")
    func unknownValues() throws {
        let json = #"{"placement":{"terminal":"floating","sidebarSide":"up"}}"#
        let layout = try JSONDecoder().decode(WorkbenchLayout.self, from: Data(json.utf8))
        #expect(layout.placement == PanelPlacement())
    }

    @Test("摆放配置编码后可原样解码")
    func roundTrip() throws {
        var layout = WorkbenchLayout()
        layout.placement = PanelPlacement(terminal: .right, sidebarSide: .right, toolsSide: .left)
        layout.terminalVisible = true
        layout.terminalWidth = 555
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(WorkbenchLayout.self, from: data) == layout)
    }

    @Test("校正:终端不在底部时底部面板回到输出,终端不在侧栏时侧栏隐藏,宽度被限制")
    func normalization() {
        var layout = WorkbenchLayout()
        layout.placement.terminal = .editor
        layout.bottomPane = .terminal
        layout.terminalVisible = true
        layout.terminalWidth = 99999
        layout.clamp()
        #expect(layout.bottomPane == .output)
        #expect(!layout.terminalVisible)
        #expect(layout.terminalWidth == PanelMetrics.terminalRange.upperBound)
    }

    @Test("通用分隔条换算:左侧列向右拖变宽,右侧列向左拖变宽,并限制在范围内")
    func resizing() {
        let range = PanelMetrics.terminalRange
        #expect(PanelMetrics.resized(base: 400, translation: 50, side: .left, range: range) == 450)
        #expect(PanelMetrics.resized(base: 400, translation: 50, side: .right, range: range) == 350)
        #expect(PanelMetrics.resized(base: 400, translation: -900, side: .left, range: range) == range.lowerBound)
        #expect(PanelMetrics.resized(base: 400, translation: -900, side: .right, range: range) == range.upperBound)
    }
}

@Suite("终端拖动落点")
struct TerminalDropTargetTests {
    private let size = CGSize(width: 1000, height: 800)

    @Test("四个区域映射到对应摆放位置")
    func zones() {
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 50, y: 400), in: size) == .left)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 950, y: 400), in: size) == .right)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 500, y: 780), in: size) == .bottom)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 500, y: 400), in: size) == .editor)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 500, y: 10), in: size) == .editor)
    }

    @Test("指针在工作区之外时取消")
    func outside() {
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: -5, y: 100), in: size) == nil)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 500, y: 900), in: size) == nil)
        #expect(TerminalPlacement.dropTarget(at: CGPoint(x: 5, y: 5), in: .zero) == nil)
    }

    @Test("高亮区域落在工作区内且与落点一致")
    func highlight() {
        for placement in TerminalPlacement.allCases {
            let rect = placement.highlight(in: size)
            #expect(CGRect(origin: .zero, size: size).contains(rect))
        }
        let left = TerminalPlacement.left.highlight(in: size)
        #expect(left.minX == 0 && left.width == 250 && left.height == 800)
        let bottom = TerminalPlacement.bottom.highlight(in: size)
        #expect(bottom.maxY == 800 && bottom.height == 200)
    }
}
