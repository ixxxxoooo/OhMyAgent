// @author ixxxxoooo
// ISO8601 解析记忆化测试:结果与原解析一致、重复读取命中缓存、非法串也被记住、容量有界。
// 每个用例使用独立的缓存实例,不受并行测试对全局缓存的影响。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("ISO8601 解析缓存")
struct DateParseCacheTests {
    @Test("含/不含毫秒都能解析,结果与直接解析一致")
    func parsesBothForms() {
        let withMs = WorkbenchModel.parseDate("2026-10-19T08:30:15.250Z")
        let without = WorkbenchModel.parseDate("2026-10-19T08:30:15Z")
        #expect(withMs != nil)
        #expect(without != nil)
        if let withMs, let without { #expect(abs(withMs.timeIntervalSince(without) - 0.25) < 0.001) }
        #expect(WorkbenchModel.parseDate(nil) == nil)
    }

    @Test("重复解析同一字符串只实际解析一次(含非法串)")
    func memoizes() {
        let cache = DateParseCache()
        for _ in 0..<50 {
            _ = cache.date(for: "2026-10-19T08:30:15.250Z")
            _ = cache.date(for: "not-a-date")
        }
        #expect(cache.parseCount == 2)
        #expect(cache.date(for: "not-a-date") == nil)
    }

    @Test("条目数达到容量后整体清空,不会无限增长")
    func boundedCapacity() {
        let cache = DateParseCache(capacity: 100)
        for index in 0..<110 { _ = cache.date(for: "x\(index)") }
        #expect(cache.parseCount == 110)
        // 超过容量时已整体清空:最早的串需要重新解析
        let before = cache.parseCount
        _ = cache.date(for: "x0")
        #expect(cache.parseCount == before + 1)
    }
}
