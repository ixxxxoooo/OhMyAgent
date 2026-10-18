// @author ixxxxoooo

import Testing
@testable import WorkbenchKit

@Suite("最小模式")
struct CompactLayoutTests {
    @Test("变窄自动收起,拉宽后恢复")
    func collapseAndRestore() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = true
        layout.rightVisible = true
        policy.update(width: 700, layout: &layout)
        #expect(policy.isCompact && !layout.leftVisible && !layout.rightVisible)
        policy.update(width: 1000, layout: &layout)
        #expect(!policy.isCompact && layout.leftVisible && layout.rightVisible)
    }

    @Test("手动收起的面板不会被自动展开")
    func manualStaysClosed() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = false
        layout.rightVisible = false
        policy.update(width: 600, layout: &layout)
        policy.update(width: 1000, layout: &layout)
        #expect(!layout.leftVisible && !layout.rightVisible)
    }

    @Test("回差区间内不抖动")
    func hysteresis() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = true
        policy.update(width: 700, layout: &layout)
        policy.update(width: 800, layout: &layout)
        #expect(policy.isCompact && !layout.leftVisible)
    }
}
