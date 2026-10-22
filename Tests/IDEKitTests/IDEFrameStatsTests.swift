// @author ixxxxoooo
// 帧间隔滚动统计测试(Perf HUD 数据层):窗口截断、帧率、P95、掉帧判定与非法输入。

import Foundation
import IDEKit
import Testing

@Suite("IDE 帧间隔统计")
struct IDEFrameStatsTests {
    @Test("空窗口所有读数为 0")
    func empty() {
        let stats = IDEFrameStats()
        #expect(stats.fps == 0 && stats.maxMs == 0 && stats.p95Ms == 0 && stats.hitches == 0)
    }

    @Test("稳定 60Hz:约 60fps、没有掉帧")
    func steady() {
        var stats = IDEFrameStats(capacity: 60, expectedMs: 1000.0 / 60.0)
        for _ in 0..<60 { stats.record(1000.0 / 60.0) }
        #expect(abs(stats.fps - 60) < 0.01)
        #expect(stats.hitches == 0)
        #expect(abs(stats.maxMs - 1000.0 / 60.0) < 0.0001)
    }

    @Test("超过 1.5 倍预期间隔计为掉帧,P95 与最长随之升高")
    func hitches() {
        var stats = IDEFrameStats(capacity: 100, expectedMs: 16.0)
        for _ in 0..<95 { stats.record(16) }
        for _ in 0..<5 { stats.record(40) }
        #expect(stats.hitches == 5)
        #expect(stats.maxMs == 40)
        #expect(stats.p95Ms == 40)
        // 恰为 1.5 倍不算掉帧
        var edge = IDEFrameStats(capacity: 10, expectedMs: 16)
        edge.record(24)
        #expect(edge.hitches == 0)
    }

    @Test("超过容量只保留最近的帧")
    func capacity() {
        var stats = IDEFrameStats(capacity: 3, expectedMs: 16)
        for value in [100.0, 100, 16, 16, 16] { stats.record(value) }
        #expect(stats.intervals == [16, 16, 16])
        #expect(stats.hitches == 0)
    }

    @Test("非法输入被忽略,reset 清空,容量与预期间隔有兜底")
    func invalidInput() {
        var stats = IDEFrameStats(capacity: 0, expectedMs: -1)
        #expect(stats.capacity == 1)
        #expect(abs(stats.expectedMs - 1000.0 / 60.0) < 0.0001)
        for value in [0.0, -3, .infinity, .nan] { stats.record(value) }
        #expect(stats.intervals.isEmpty)
        stats.record(8)
        #expect(stats.intervals == [8])
        stats.reset()
        #expect(stats.intervals.isEmpty)
    }
}
