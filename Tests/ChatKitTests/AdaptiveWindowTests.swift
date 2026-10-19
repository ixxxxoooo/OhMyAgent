// @author ixxxxoooo
// 事件合并器的自适应窗口:处理越慢窗口越长,有上下限,变快后缓慢恢复。

import Foundation
import Testing

@testable import ChatKit

@Suite("自适应合并窗口")
struct AdaptiveWindowTests {
    @Test("处理很快时保持基础窗口")
    func fastKeepsBase() {
        var window = AdaptiveWindow(base: .milliseconds(16))
        for _ in 0..<20 { window.record(.milliseconds(1)) }
        #expect(window.interval == .milliseconds(16))
    }

    @Test("处理变慢时窗口约为处理耗时的两倍")
    func slowStretchesWindow() {
        var window = AdaptiveWindow(base: .milliseconds(16))
        for _ in 0..<30 { window.record(.milliseconds(20)) }
        let ms = Double(window.interval.components.attoseconds) / 1e15 + Double(window.interval.components.seconds) * 1000
        #expect(ms > 35 && ms <= 41)
    }

    @Test("窗口不超过上限,也不小于基础窗口")
    func clampedToBounds() {
        var window = AdaptiveWindow(base: .milliseconds(16), ceiling: .milliseconds(80))
        for _ in 0..<30 { window.record(.milliseconds(500)) }
        #expect(window.interval == .milliseconds(80))
        // 基础窗口大于上限时以基础窗口为准(测试里用很长的基础窗口)
        let long = AdaptiveWindow(base: .seconds(10))
        #expect(long.interval == .seconds(10))
    }

    @Test("变快后逐步恢复,不会瞬间回到基础窗口")
    func recoversGradually() {
        var window = AdaptiveWindow(base: .milliseconds(16))
        for _ in 0..<30 { window.record(.milliseconds(40)) }
        let stretched = window.interval
        window.record(.milliseconds(1))
        #expect(window.interval < stretched)
        #expect(window.interval > .milliseconds(16))
    }

    @Test("合并器按处理耗时调整当前窗口,未提供耗时则不变")
    func coalescerAdjusts() {
        let coalescer = EventCoalescer()
        #expect(coalescer.currentInterval == .milliseconds(16))
        coalescer.markApplied(1)
        #expect(coalescer.currentInterval == .milliseconds(16))
        for _ in 0..<30 { coalescer.markApplied(1, elapsed: .milliseconds(30)) }
        #expect(coalescer.currentInterval > .milliseconds(40))
    }
}
