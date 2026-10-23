// @author ixxxxoooo
// 侧栏模式切换控件:能否与左上浮层同一行的判断。

import Testing
@testable import OhMyAgentApp

@Suite("侧栏模式切换位置")
struct SidebarModeSwitchTests {
    @Test("默认宽度 260 放得下,最窄 200 放不下(退到下一行)")
    func fits() {
        #expect(TitlebarMetrics.sidebarSwitchFitsInStrip(sidebarWidth: 260, toggles: 1))
        #expect(TitlebarMetrics.sidebarSwitchFitsInStrip(sidebarWidth: 400, toggles: 1))
        #expect(!TitlebarMetrics.sidebarSwitchFitsInStrip(sidebarWidth: 200, toggles: 1))
    }

    @Test("侧栏在右侧时浮层不压在侧栏上,任何宽度都放得下")
    func rightSide() {
        #expect(TitlebarMetrics.sidebarSwitchFitsInStrip(sidebarWidth: 200, toggles: 1, overlayOnSidebarSide: false))
    }
}
