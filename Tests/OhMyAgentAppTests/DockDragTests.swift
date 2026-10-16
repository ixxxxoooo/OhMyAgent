// @author ixxxxoooo
// 标签拖拽状态测试:开始拖拽记录标签,松手后自动复位(源标签不会一直隐藏)。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("标签拖拽状态")
struct DockDragTests {
    @Test("开始拖拽记录标签,鼠标已抬起时延迟后自动复位")
    func beginAndReset() async throws {
        let drag = DockDrag.shared
        let id = UUID()
        drag.begin(id)
        #expect(drag.tabID == id)
        try await Task.sleep(for: .milliseconds(900))
        #expect(drag.tabID == nil)
    }

    @Test("拖拽载荷往返解析")
    func payloadRoundTrip() throws {
        let id = UUID()
        let text = DockDrag.prefix + id.uuidString
        #expect(DockDrag.parse(text) == id)
        #expect(DockDrag.parse("other") == nil)
    }
}
