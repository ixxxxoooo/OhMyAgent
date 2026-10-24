// @author ixxxxoooo
// IDE 窗口自适应布局:变窄依次让出 Agent 面板与侧栏,变宽恢复,宽度始终不挤占编辑区最小宽度。

import Testing
@testable import IDEKit

@Suite("IDE 自适应布局")
struct IDEResponsiveLayoutTests {
    private func resolve(_ window: Double, sidebar: Bool = true, agent: Bool = true) -> IDEResponsiveLayout {
        IDEResponsiveLayout.resolve(window: window, sidebarVisible: sidebar, sidebarWidth: 260, agentVisible: agent, agentWidth: 380)
    }

    @Test("宽窗口保持用户宽度")
    func wideKeepsStored() {
        let layout = resolve(1400)
        #expect(layout.sidebarShown && layout.agentShown)
        #expect(layout.sidebarWidth == 260 && layout.agentWidth == 380)
    }

    @Test("变窄时先收侧栏,再收编辑区,最后只剩 Agent 面板;变宽后恢复")
    func collapsesInOrder() {
        let mid = resolve(800)
        #expect(!mid.sidebarShown && mid.editorShown && mid.agentShown)
        let narrow = resolve(500)
        #expect(!narrow.sidebarShown && !narrow.editorShown && narrow.agentShown)
        let wide = resolve(1400)
        #expect(wide.sidebarShown && wide.editorShown && wide.agentShown)
        // Agent 面板没开时编辑区不会被收掉
        #expect(resolve(400, agent: false).editorShown)
    }

    @Test("显示出来的面板不会挤占编辑区最小宽度;未打开的面板宽度为 0")
    func keepsEditorMin() {
        for width in stride(from: 400.0, through: 1600.0, by: 20.0) {
            let layout = resolve(width)
            let used = IDEMetrics.activityBarWidth + layout.sidebarWidth + layout.agentWidth
            #expect(!layout.editorShown || width - used >= IDEMetrics.editorMinWidth || width < IDEMetrics.activityBarWidth + IDEMetrics.editorMinWidth)
        }
        let off = resolve(1400, sidebar: false, agent: false)
        #expect(off.sidebarWidth == 0 && off.agentWidth == 0)
    }
}
