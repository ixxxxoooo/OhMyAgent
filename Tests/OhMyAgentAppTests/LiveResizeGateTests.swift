// @author ixxxxoooo
// 实时缩放门控测试:门控期间暂存、结束时一次性应用、与当前尺寸相同不重排。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("终端实时缩放门控")
struct LiveResizeGateTests {
    private let base = NSSize(width: 600, height: 300)

    @Test("非门控:立即应用并清空暂存")
    func ungatedAppliesImmediately() {
        var gate = LiveResizeGate()
        #expect(gate.submit(NSSize(width: 500, height: 300), gated: false, current: base) == NSSize(width: 500, height: 300))
        #expect(gate.pending == nil)
    }

    @Test("门控期间只暂存最新尺寸,不应用")
    func gatedKeepsLatest() {
        var gate = LiveResizeGate()
        for width in stride(from: 590.0, through: 400, by: -10) {
            #expect(gate.submit(NSSize(width: width, height: 300), gated: true, current: base) == nil)
        }
        #expect(gate.pending == NSSize(width: 400, height: 300))
        // 结束时一次性应用最新值,之后不再有待应用尺寸
        #expect(gate.flush(current: base) == NSSize(width: 400, height: 300))
        #expect(gate.pending == nil)
        #expect(gate.flush(current: base) == nil)
    }

    @Test("拖回原尺寸:没有待应用的尺寸,不触发重排")
    func backToCurrentDropsPending() {
        var gate = LiveResizeGate()
        _ = gate.submit(NSSize(width: 500, height: 300), gated: true, current: base)
        _ = gate.submit(base, gated: true, current: base)
        #expect(gate.pending == nil)
        #expect(gate.flush(current: base) == nil)
    }

    @Test("门控期间的暂存在门控结束后的下一次提交时被新尺寸取代")
    func ungatedSubmitClearsPending() {
        var gate = LiveResizeGate()
        _ = gate.submit(NSSize(width: 450, height: 300), gated: true, current: base)
        let final = NSSize(width: 460, height: 300)
        #expect(gate.submit(final, gated: false, current: base) == final)
        #expect(gate.pending == nil)
    }

    @Test("停稳兜底延迟约 100ms")
    func settleDelay() {
        #expect(LiveResizeGate.settleDelay == .milliseconds(100))
    }
}
