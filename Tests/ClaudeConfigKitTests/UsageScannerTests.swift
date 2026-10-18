// @author ixxxxoooo
// 会话记录用量汇总:流式多行去重、费用取自 cost-state、跨文件合并与缓存复用。

import Foundation
import Testing
@testable import ClaudeConfigKit

@Suite("会话记录用量汇总")
struct UsageScannerTests {
    private func assistant(id: String, req: String, model: String = "claude-sonnet-5-5", stamp: String, input: Int, output: Int, cacheRead: Int = 0, tool: String? = nil, session: String = "s1") -> String {
        let content = tool.map { "[{\"type\":\"tool_use\",\"id\":\"\($0)\"}]" } ?? "[{\"type\":\"text\",\"text\":\"hi\"}]"
        return "{\"type\":\"assistant\",\"sessionId\":\"\(session)\",\"requestId\":\"\(req)\",\"timestamp\":\"\(stamp)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"content\":\(content),\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":0}}}"
    }

    @Test("同一消息被流式拆成多行:只算一条,各字段取最大值;工具调用按 id 去重;合成消息忽略")
    func dedupesStreamedLines() {
        let lines = [
            assistant(id: "m1", req: "r1", stamp: "2026-10-18T05:00:00.000Z", input: 5, output: 10, tool: "t1"),
            assistant(id: "m1", req: "r1", stamp: "2026-10-18T05:00:01.000Z", input: 5, output: 120, tool: "t1"),
            assistant(id: "m2", req: "r2", stamp: "2026-10-18T05:01:00.000Z", input: 7, output: 30, cacheRead: 900),
            assistant(id: "m3", req: "r3", model: "<synthetic>", stamp: "2026-10-18T05:02:00.000Z", input: 0, output: 0),
            "{\"type\":\"user\",\"message\":{}}",
        ].joined(separator: "\n")
        let usage = UsageScanner.parse(Data(lines.utf8))
        let day = usage.days.values.reduce(DayUsage()) { acc, d in DayUsage(messages: acc.messages + d.messages, tools: acc.tools + d.tools, tokens: acc.tokens.merging(d.tokens) { $0 + $1 }) }
        #expect(day.messages == 2)
        #expect(day.tools == 1)
        #expect(day.tokens["claude-sonnet-5-5"] == [12, 150, 900, 0])
        #expect(usage.sessionId == "s1")
    }

    @Test("费用取每个会话最后一条 cost-state;按模型累计;同一会话在多个文件只取最大的一份")
    func costFromCostState() throws {
        func state(_ total: Double, _ model: Double) -> String {
            "{\"type\":\"cost-state\",\"sessionId\":\"s1\",\"totalCostUSD\":\(total),\"modelUsage\":{\"claude-sonnet-5-5\":{\"costUSD\":\(model)}}}"
        }
        let a = [assistant(id: "m1", req: "r1", stamp: "2026-10-18T05:00:00.000Z", input: 1, output: 1), state(0.1, 0.1), state(0.5, 0.5)].joined(separator: "\n")
        let b = [assistant(id: "m9", req: "r9", stamp: "2026-10-19T05:00:00.000Z", input: 1, output: 1), state(0.2, 0.2)].joined(separator: "\n")
        let files: [String: FileUsage] = ["a": UsageScanner.parse(Data(a.utf8)), "b": UsageScanner.parse(Data(b.utf8))]
        let snapshot = try #require(UsageScanner.merge(files))
        #expect(abs(snapshot.totalCostUSD - 0.5) < 1e-9, "同一会话只应计一次(取最大)")
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.source == .transcripts(sessions: 1, costSessions: 1))
        #expect(UsageScanner.merge([:]) == nil)
    }

    @Test("扫描目录:递归包含子代理文件,第二次扫描复用缓存(改动文件才重新解析)")
    func scansDirectoryWithCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("p/s1/subagents")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try assistant(id: "m1", req: "r1", stamp: "2026-10-18T05:00:00.000Z", input: 1, output: 10).write(to: root.appendingPathComponent("p/s1.jsonl"), atomically: true, encoding: .utf8)
        try assistant(id: "m2", req: "r2", stamp: "2026-10-18T05:00:00.000Z", input: 2, output: 20).write(to: project.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent("cache.json")
        let scanner = UsageScanner(projectsDirectory: root.appendingPathComponent("p"), cacheURL: cache)
        let first = try #require(scanner.scan())
        #expect(first.models.first?.outputTokens == 30)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        let second = try #require(scanner.scan())
        #expect(second == first)
    }
}
