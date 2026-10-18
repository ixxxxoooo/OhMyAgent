// @author ixxxxoooo
// 会话记录回合解析测试。

import Foundation
import Testing
@testable import ChatKit

@Suite("TranscriptTurns")
struct TranscriptTurnsTests {
    @Test("按提问切分回合,工具结果与元信息不算新回合,完成时间取回合内最后一条记录")
    func parsesTurns() {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-17T09:00:00.000Z","message":{"role":"user","content":"你好"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:00:05.000Z","message":{"role":"assistant","model":"m1","content":[{"type":"tool_use"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-17T09:00:06.000Z","sourceToolAssistantUUID":"x","message":{"role":"user","content":[{"type":"tool_result"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:00:22.000Z","message":{"role":"assistant","model":"m2","content":[{"type":"text"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-17T09:01:00.000Z","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","timestamp":"2026-10-17T09:02:00.000Z","message":{"role":"user","content":[{"type":"text"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:02:03.500Z","isSidechain":true,"message":{"role":"assistant","model":"side","content":[]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:02:04.000Z","message":{"role":"assistant","model":"m3","content":[{"type":"text"}]}}"#,
        ].joined(separator: "\n")
        let turns = TranscriptTurns.parse(Data(lines.utf8))
        #expect(turns.count == 2)
        #expect(turns[0].model == "m2")
        #expect(turns[0].end.timeIntervalSince(turns[0].start) == 22)
        #expect(turns[1].model == "m3")
        #expect(turns[1].end.timeIntervalSince(turns[1].start) == 4)
    }

    @MainActor
    @Test("回放的历史回合按末尾对齐补上结束行,已有结束行不重复")
    func attachesSummaries() {
        let store = TimelineStore()
        store.appendUser("q1")
        store.apply(.agentMessageChunk(messageId: "m1", content: .text("a1")))
        store.appendUser("q2")
        store.apply(.agentMessageChunk(messageId: "m2", content: .text("a2")))
        let t0 = Date(timeIntervalSince1970: 1_000)
        let turns = [TranscriptTurn(start: t0, end: t0.addingTimeInterval(10), model: "m"),
                     TranscriptTurn(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(65), model: "m")]
        store.attachReplayedSummaries(turns)
        #expect(store.entries.map(\.kind).filter { $0 == .turnSummary }.count == 2)
        #expect(store.entries[2].kind == .turnSummary && store.entries[2].summary?.durationSeconds == 10)
        store.attachReplayedSummaries(turns)
        #expect(store.entries.filter { $0.kind == .turnSummary }.count == 2)
    }

    @Test("回合 token 用量:同一消息 ID 的多行只算一次,多次请求累加")
    func sumsUsagePerMessage() {
        let lines = [
            #"{"type":"user","timestamp":"2026-10-18T05:00:00.000Z","message":{"content":"q"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-18T05:00:01.000Z","message":{"id":"a","model":"m","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-18T05:00:02.000Z","message":{"id":"a","model":"m","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-18T05:00:03.000Z","message":{"id":"b","model":"m","usage":{"input_tokens":2,"output_tokens":3,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}}"#,
        ].joined(separator: "\n")
        let usage = TranscriptTurns.parse(Data(lines.utf8)).first?.usage
        #expect(usage?.inputTokens == 12)
        #expect(usage?.outputTokens == 23)
        #expect(usage?.cachedReadTokens == 150)
        #expect(usage?.cachedWriteTokens == 5)
    }
}
