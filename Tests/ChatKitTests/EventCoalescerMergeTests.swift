// @author ixxxxoooo
// 事件合并器的文本增量合并:同条消息相邻增量拼成一个事件,不跨事件重排,积压计数不失衡。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("事件合并器:文本增量合并")
struct EventCoalescerMergeTests {
    private func agent(_ text: String, id: String? = "m1", session: String = "s") -> ClientEvent {
        .sessionUpdate(sessionId: session, update: .agentMessageChunk(messageId: id, content: .text(text)))
    }

    private func texts(_ events: [ClientEvent]) -> [String] {
        events.map { event in
            guard case .sessionUpdate(_, let update) = event else { return "·" }
            switch update {
            case .agentMessageChunk(_, .text(let value)): return "A:\(value)"
            case .agentThoughtChunk(_, .text(let value)): return "T:\(value)"
            case .userMessageChunk(_, .text(let value)): return "U:\(value)"
            default: return "?"
            }
        }
    }

    @Test("同一条消息的相邻文本增量合并为一个事件")
    func mergesAdjacent() {
        let merged = EventCoalescer.merge([agent("你"), agent("好"), agent(","), agent("世界")])
        #expect(texts(merged) == ["A:你好,世界"])
    }

    @Test("messageId、会话或种类不同则不合并;中间夹着其他事件也不合并")
    func respectsBoundaries() {
        let thought = ClientEvent.sessionUpdate(sessionId: "s", update: .agentThoughtChunk(messageId: "m1", content: .text("想")))
        let events = [agent("a"), agent("b", id: "m2"), agent("c", session: "other"), thought, agent("d"), .stderr("x"), agent("e")]
        #expect(texts(EventCoalescer.merge(events)) == ["A:a", "A:b", "A:c", "T:想", "A:d", "·", "A:e"])
    }

    @Test("两个 messageId 都为空时视为同一条消息;非文本内容不合并")
    func nilIdsAndImages() {
        let image = ClientEvent.sessionUpdate(sessionId: "s", update: .agentMessageChunk(messageId: nil, content: .image(data: "AA", mimeType: "image/png", uri: nil)))
        let merged = EventCoalescer.merge([agent("a", id: nil), agent("b", id: nil), image, agent("c", id: nil)])
        #expect(merged.count == 3)
        #expect(texts(merged).first == "A:ab")
    }

    @Test("空批与单事件原样返回")
    func trivial() {
        #expect(EventCoalescer.merge([]).isEmpty)
        #expect(EventCoalescer.merge([agent("x")]).count == 1)
    }

    @Test("合并后 drain 仍能等到全部应用(被合并的事件计入已应用)")
    func drainAccounting() async {
        let coalescer = EventCoalescer(interval: .milliseconds(5))
        let consumer = Task {
            var applied = 0
            for await batch in coalescer.batches {
                applied += batch.count
                coalescer.markApplied(batch.count)
            }
            return applied
        }
        for index in 0..<50 { coalescer.push(agent("t\(index)")) }
        let drained = await coalescer.drain(timeout: .seconds(2))
        #expect(drained)
        coalescer.finish()
        let applied = await consumer.value
        #expect(applied >= 1 && applied <= 50)
    }
}
