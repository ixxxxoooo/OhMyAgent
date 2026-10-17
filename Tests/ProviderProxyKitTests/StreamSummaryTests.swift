// @author ixxxxoooo
// 代理流汇总测试:首块耗时只记一次、块数与字节累计、日志字段不含正文与密钥。

import Foundation
import OMLog
import Testing
@testable import ProviderProxyKit

@Suite("代理流汇总")
struct StreamSummaryTests {
    @Test("首块耗时只记录第一次,块数与字节累计")
    func counting() async throws {
        var summary = StreamSummary(route: "r1", wire: "openai", started: .now - .milliseconds(120))
        #expect(summary.firstChunkMs == nil)
        summary.noteChunk(bytes: 10)
        let first = try #require(summary.firstChunkMs)
        #expect(first >= 120)
        try await Task.sleep(for: .milliseconds(30))
        summary.noteChunk(bytes: 5)
        #expect(summary.firstChunkMs == first)
        #expect(summary.chunks == 2 && summary.bytes == 15)
    }

    @Test("汇总写入聚合统计,出错时升级为 warning")
    func logging() {
        let before = PerfStats.shared.snapshot(top: 1000).first { $0.name == "代理流(anthropic)" }?.count ?? 0
        var summary = StreamSummary(route: "r2", wire: "anthropic", started: .now)
        summary.noteChunk(bytes: 1)
        summary.log()
        summary.outcome = "error"
        summary.log()
        let after = PerfStats.shared.snapshot(top: 1000).first { $0.name == "代理流(anthropic)" }?.count ?? 0
        #expect(after - before == 2)
    }
}
