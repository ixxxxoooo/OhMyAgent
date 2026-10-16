// @author ixxxxoooo
// 面板摆放的界面侧逻辑:标题栏浮层让位宽度、面板列的让位边距、终端拖动状态。

import CoreGraphics
import Foundation
import Testing
import WorkbenchKit
@testable import OhMyAgentApp

@MainActor
@Suite("面板摆放(界面侧)")
struct PanelPlacementViewTests {
    @Test("浮层让位宽度:默认一个开关时与旧常量一致(170 / 34),没有开关时为 0")
    func clusterWidths() {
        #expect(TitlebarMetrics.leftClusterWidth(toggles: 1) == 170)
        #expect(TitlebarMetrics.rightClusterWidth(toggles: 1) == 34)
        #expect(TitlebarMetrics.rightClusterWidth(toggles: 0) == 0)
        #expect(TitlebarMetrics.leftClusterWidth(toggles: 2) > TitlebarMetrics.leftClusterWidth(toggles: 1))
    }

    @Test("只有最外侧的可见工具栏/终端列才需要给浮层让位,项目栏不需要")
    func columnInsets() {
        var layout = WorkbenchLayout()
        layout.rightVisible = true
        // 默认:工具栏在右侧最外
        #expect(layout.titlebarInsets(for: .tools) == (0, TitlebarMetrics.rightClusterWidth(toggles: 1)))
        #expect(layout.titlebarInsets(for: .sidebar) == (0, 0))

        // 工具栏换到左侧且项目栏隐藏:工具栏成为左侧最外列,需要让开红绿灯与回退/前进/开关
        layout.placement = PanelPlacement(terminal: .bottom, sidebarSide: .left, toolsSide: .left)
        layout.leftVisible = false
        #expect(layout.titlebarInsets(for: .tools) == (TitlebarMetrics.leftClusterWidth(toggles: 2), 0))

        // 项目栏可见时,工具栏在内侧,无需让位
        layout.leftVisible = true
        #expect(layout.titlebarInsets(for: .tools) == (0, 0))

        // 右侧没有任何开关时,终端侧栏无需让位;项目栏换到右侧(隐藏)后终端成为最外列,需要为其开关让位
        layout.placement.terminal = .right
        layout.terminalVisible = true
        #expect(layout.titlebarInsets(for: .terminal) == (0, 0))
        layout.placement.sidebarSide = .right
        layout.leftVisible = false
        #expect(layout.titlebarInsets(for: .terminal) == (0, TitlebarMetrics.rightClusterWidth(toggles: 1)))
    }

    @Test("终端拖动状态:按工作区范围换算落点,越界取消")
    func dragState() {
        let drag = TerminalDragState.shared
        drag.workspaceFrame = CGRect(x: 100, y: 50, width: 1000, height: 800)
        drag.update(CGPoint(x: 150, y: 450), panel: .terminal)
        #expect(drag.isDragging && drag.target == .left)
        #expect(drag.finish(at: CGPoint(x: 1080, y: 450)) == .right)
        #expect(!drag.isDragging && drag.target == nil)
        drag.update(CGPoint(x: 10, y: 10), panel: .terminal)
        #expect(drag.finish(at: CGPoint(x: 10, y: 10)) == nil)
    }
}
