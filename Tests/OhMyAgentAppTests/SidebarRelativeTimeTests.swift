// @author ixxxxoooo
// 侧栏相对时间缓存:同一分钟内复用文案,跨分钟重新计算,且与系统格式化结果一致。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("侧栏相对时间缓存")
struct SidebarRelativeTimeTests {
    @Test("结果与系统格式化一致")
    func matchesSystemFormat() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = now.addingTimeInterval(-300)
        #expect(SidebarRelativeTime.text(for: date, now: now) == date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
    }

    @Test("同一分钟内重复调用结果稳定")
    func stableWithinMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = now.addingTimeInterval(-3_600)
        let first = SidebarRelativeTime.text(for: date, now: now)
        #expect(SidebarRelativeTime.text(for: date, now: now.addingTimeInterval(10)) == first)
    }
}
