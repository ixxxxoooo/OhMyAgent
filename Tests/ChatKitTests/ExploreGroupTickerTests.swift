// @author ixxxxoooo
// 工具分组「最新一步」判定:并行工具与工具间空窗。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("分组最新一步")
struct ExploreGroupTickerTests {
    private func group(_ statuses: [ToolStatus]) -> ExploreGroup {
        let store = TimelineStore()
        for (index, status) in statuses.enumerated() {
            store.apply(.toolCall(ToolCall(toolCallId: "t\(index)", name: "Read", kind: .read, status: status)))
        }
        return ExploreGroup(id: UUID(), entries: store.entries)
    }

    @Test("最后一个工具运行中:展示它,不算空窗")
    func runningLast() {
        let g = group([.completed, .inProgress])
        #expect(g.tickerEntry?.tool?.toolCallId == "t1")
        #expect(!g.isBetweenSteps)
    }

    @Test("全部结束:展示最后一个工具并视为空窗")
    func allDone() {
        let g = group([.completed, .completed])
        #expect(g.tickerEntry?.tool?.toolCallId == "t1")
        #expect(g.isBetweenSteps)
    }

    @Test("并行调用:后启动的先结束时,仍展示运行中的那个,不显示空窗")
    func parallel() {
        let g = group([.inProgress, .completed])
        #expect(g.tickerEntry?.tool?.toolCallId == "t0")
        #expect(!g.isBetweenSteps)
    }

    @Test("没有工具:视为空窗")
    func empty() {
        let g = ExploreGroup(id: UUID(), entries: [])
        #expect(g.tickerEntry == nil)
        #expect(g.isBetweenSteps)
    }
}
