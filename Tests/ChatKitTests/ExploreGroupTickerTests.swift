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

    @Test("精简档:列表末尾的尾部思考留在分组内,且流式时判定为思考尾巴")
    func compactTrailingThoughtStaysInGroup() {
        let s = TimelineStore()
        s.apply(.toolCall(ToolCall(toolCallId: "a", name: "Read", kind: .read, status: .completed)))
        s.apply(.toolCall(ToolCall(toolCallId: "b", name: "Read", kind: .read, status: .completed)))
        s.apply(.agentThoughtChunk(messageId: nil, content: .text("想")))
        let items = TimelineGrouping.group(s.entries, density: .compact)
        #expect(items.count == 1)
        guard case .explore(let g) = items[0] else { Issue.record("应为分组"); return }
        #expect(g.isThinkingTail)
        #expect(g.isRunning)
    }

    @Test("精简档:后面还有正文时,尾部思考不并入分组")
    func compactThoughtBeforeTextStaysOut() {
        let s = TimelineStore()
        s.apply(.toolCall(ToolCall(toolCallId: "a", name: "Read", kind: .read, status: .completed)))
        s.apply(.toolCall(ToolCall(toolCallId: "b", name: "Read", kind: .read, status: .completed)))
        s.apply(.agentThoughtChunk(messageId: nil, content: .text("想")))
        s.apply(.agentMessageChunk(messageId: nil, content: .text("结论")))
        let items = TimelineGrouping.group(s.entries, density: .compact)
        #expect(items.count == 3)
        guard case .explore(let g) = items[0] else { Issue.record("应为分组"); return }
        #expect(!g.isThinkingTail)
    }
}
