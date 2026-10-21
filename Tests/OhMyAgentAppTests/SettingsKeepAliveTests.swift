// @author ixxxxoooo
// 设置页保活测试:LRU 裁剪、按需加载页不保活、挂载顺序稳定。

import Testing
@testable import OhMyAgentApp

@Suite("设置页保活")
struct SettingsKeepAliveTests {
    @Test("超过上限时淘汰最久未访问的页面")
    func evictsLeastRecent() {
        var keep = SettingsKeepAlive(limit: 2)
        keep.visit(.general)
        keep.visit(.appearance)
        keep.visit(.editor)
        #expect(keep.recent == [.editor, .appearance])
        keep.visit(.appearance)
        #expect(keep.recent == [.appearance, .editor])
    }

    @Test("进入时加载数据的页面不保活,但当前显示时仍挂载")
    func reloadPagesNotKept() {
        var keep = SettingsKeepAlive()
        keep.visit(.general)
        keep.visit(.diagnostics)
        #expect(keep.recent == [.general])
        #expect(keep.mounted(current: .diagnostics) == [.general, .diagnostics])
    }

    @Test("挂载顺序与访问顺序无关,保证视图层级稳定")
    func stableOrder() {
        var keep = SettingsKeepAlive()
        keep.visit(.about)
        keep.visit(.general)
        #expect(keep.mounted(current: .general) == [.general, .about])
    }
}
