// @author ixxxxoooo
// ISO8601 解析记忆化测试:结果与原解析一致、重复读取命中缓存、非法串也被记住、容量有界。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("ISO8601 解析缓存", .serialized)
struct DateParseCacheTests {
    @Test("含/不含毫秒都能解析,结果与直接解析一致")
    func parsesBothForms() {
        DateParseCache.reset()
        let withMs = WorkbenchModel.parseDate("2026-10-19T08:30:15.250Z")
        let without = WorkbenchModel.parseDate("2026-10-19T08:30:15Z")
        #expect(withMs != nil)
        #expect(without != nil)
        if let withMs, let without { #expect(abs(withMs.timeIntervalSince(without) - 0.25) < 0.001) }
        #expect(WorkbenchModel.parseDate(nil) == nil)
    }

    @Test("重复解析同一字符串只实际解析一次(含非法串)")
    func memoizes() {
        DateParseCache.reset()
        for _ in 0..<50 {
            _ = WorkbenchModel.parseDate("2026-10-19T08:30:15.250Z")
            _ = WorkbenchModel.parseDate("not-a-date")
        }
        #expect(DateParseCache.parseCount == 2)
        #expect(WorkbenchModel.parseDate("not-a-date") == nil)
    }

    @Test("条目数超过容量后整体清空,不会无限增长")
    func boundedCapacity() {
        DateParseCache.reset()
        for index in 0..<(DateParseCache.capacity + 10) {
            _ = DateParseCache.date(for: "x\(index)")
        }
        #expect(DateParseCache.parseCount == DateParseCache.capacity + 10)
        // 清空后再读最早的串需重新解析
        let before = DateParseCache.parseCount
        _ = DateParseCache.date(for: "x0")
        #expect(DateParseCache.parseCount == before + 1)
    }
}
