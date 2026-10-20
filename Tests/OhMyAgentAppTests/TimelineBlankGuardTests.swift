// @author ixxxxoooo
// 时间线空白自愈判定测试。

import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
struct TimelineBlankGuardTests {
    @Test("有内容、视口有高度却没有可见条目才算空白")
    func blankDetection() {
        #expect(TimelineBlankGuard.isBlank(visibleCount: 0, hasEntries: true, containerHeight: 600))
        #expect(TimelineBlankGuard.isBlank(visibleCount: -1, hasEntries: true, containerHeight: 600))
        #expect(!TimelineBlankGuard.isBlank(visibleCount: 3, hasEntries: true, containerHeight: 600))
        #expect(!TimelineBlankGuard.isBlank(visibleCount: 0, hasEntries: false, containerHeight: 600))
        #expect(!TimelineBlankGuard.isBlank(visibleCount: 0, hasEntries: true, containerHeight: 0))
    }

    @Test("容器尺寸明显变化或内容首次出现才要求检查")
    func recordReportsResize() {
        let guardState = TimelineBlankGuard()
        #expect(guardState.record(offsetY: 0, contentHeight: 1000, containerHeight: 600))
        #expect(!guardState.record(offsetY: 50, contentHeight: 1200, containerHeight: 600))
        #expect(guardState.record(offsetY: 50, contentHeight: 1200, containerHeight: 500))
    }
}
