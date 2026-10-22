// @author ixxxxoooo
// 会话记录行的顶层字段字节扫描:字段提取、嵌套内容跳过、转义字符串、畸形行回退,以及与完整解析结果等价。

import Foundation
import Testing
@testable import ChatKit

@Suite("记录行顶层字段扫描")
struct TranscriptLineScannerTests {
    private func scan(_ line: String) -> TranscriptLineFields? {
        Array(line.utf8).withUnsafeBytes { TranscriptLineScanner.scan($0) }
    }

    @Test("提取 type、timestamp 与布尔标记;嵌套对象里的同名键不影响结果")
    func topLevelOnly() {
        let line = #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"type":"assistant","timestamp":"1999","content":[{"type":"tool_result","content":"含 \"type\":\"x\" 的文本 } ] ,"}]},"timestamp":"2026-10-17T09:00:06.000Z","isMeta":true,"toolUseResult":{"timestamp":"2000","stdout":"{[}"}}"#
        let fields = scan(line)
        #expect(fields?.type == "user")
        #expect(fields?.timestamp == "2026-10-17T09:00:06.000Z")
        #expect(fields?.isMeta == true)
        #expect(fields?.isSidechain == false)
        #expect(fields?.hasToolMarker == true)
    }

    @Test("sourceToolAssistantUUID 与 isSidechain 识别;普通提问行没有工具标记")
    func markers() {
        #expect(scan(#"{"type":"user","timestamp":"t","sourceToolAssistantUUID":"x","message":{}}"#)?.hasToolMarker == true)
        #expect(scan(#"{"type":"assistant","isSidechain":true,"timestamp":"t"}"#)?.isSidechain == true)
        let prompt = scan(#"{"type":"user","timestamp":"t","message":{"role":"user","content":"你好"}}"#)
        #expect(prompt?.hasToolMarker == false && prompt?.isMeta == false)
        // 值为 null 也算键存在(与完整解析一致)
        #expect(scan(#"{"type":"user","toolUseResult":null,"timestamp":"t"}"#)?.hasToolMarker == true)
    }

    @Test("畸形行返回 nil 以便调用方退回完整解析")
    func malformed() {
        #expect(scan("") == nil)
        #expect(scan("[1,2]") == nil)
        #expect(scan(#"{"type":"user","message":{"a":"#) == nil)
        #expect(scan(#"{"type":"user""#) == nil)
    }

    @Test("带工具标记的巨大行与完整解析结果一致(回合数、完成时间、模型)")
    func equivalentToFullParse() {
        let huge = String(repeating: "x\\n\\\"{[", count: 5000)
        let lines = [
            #"{"type":"user","timestamp":"2026-10-17T09:00:00.000Z","message":{"role":"user","content":"问"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:00:05.000Z","message":{"role":"assistant","model":"m1","id":"a","content":[{"type":"tool_use"}],"usage":{"input_tokens":3,"output_tokens":4}}}"#,
            #"{"type":"user","timestamp":"2026-10-17T09:00:09.000Z","toolUseResult":{"stdout":"\#(huge)"},"message":{"role":"user","content":[{"type":"tool_result","content":"\#(huge)"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-17T09:00:30.000Z","isMeta":true,"toolUseResult":{},"message":{}}"#,
            #"{"type":"assistant","timestamp":"2026-10-17T09:00:12.000Z","isSidechain":true,"message":{"model":"side"}}"#,
        ].joined(separator: "\n")
        let turns = TranscriptTurns.parse(Data(lines.utf8))
        #expect(turns.count == 1)
        #expect(turns[0].model == "m1")
        // 工具结果行延长到 09:00:09;元信息行(09:00:30)与旁支行不延长
        #expect(turns[0].end.timeIntervalSince(turns[0].start) == 9)
        #expect(turns[0].usage?.inputTokens == 3)
    }
}
