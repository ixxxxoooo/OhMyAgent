// @author ixxxxoooo
// 回合结束语:usage 解析、速度与文本格式、端到端(脚本化 Agent)。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@Suite("回合结束语")
struct TurnSummaryTests {
    @Test("usage 解析:取 result.usage;全 0 或缺失返回 nil")
    func parseUsage() throws {
        let json: JSONValue = ["stopReason": "end_turn", "usage": ["inputTokens": 100, "outputTokens": 40, "cachedReadTokens": 10, "cachedWriteTokens": 0, "totalTokens": 150]]
        let usage = try #require(TurnUsage(json: json))
        #expect(usage.inputTokens == 100 && usage.outputTokens == 40 && usage.totalTokens == 150)
        #expect(TurnUsage(json: ["stopReason": "end_turn"]) == nil)
        #expect(TurnUsage(json: ["usage": ["inputTokens": 0, "outputTokens": 0]]) == nil)
    }

    @Test("tps = 输出 token ÷ 耗时;耗时过短或无输出时为 nil")
    func tokensPerSecond() {
        let usage = TurnUsage(inputTokens: 100, outputTokens: 50)
        #expect(TurnSummary(model: "m", durationSeconds: 2, usage: usage).tokensPerSecond == 25)
        #expect(TurnSummary(model: "m", durationSeconds: 0.05, usage: usage).tokensPerSecond == nil)
        #expect(TurnSummary(model: "m", durationSeconds: 2, usage: nil).tokensPerSecond == nil)
        #expect(TurnSummary(model: "m", durationSeconds: 2, usage: TurnUsage(inputTokens: 5)).tokensPerSecond == nil)
    }

    @Test("文本:模型、耗时、token、tps 依次出现,无 usage 时只有模型与耗时")
    func text() {
        let full = TurnSummary(model: "GLM 5", durationSeconds: 12.34, usage: TurnUsage(inputTokens: 1200, outputTokens: 360))
        #expect(full.parts.count == 4 && full.parts[0] == "GLM 5")
        #expect(full.copyText.contains("GLM 5") && full.copyText.contains("tps") && full.copyText.contains("360"))
        let plain = TurnSummary(model: "", durationSeconds: 3)
        #expect(plain.parts.count == 1)
        #expect(TurnSummary(model: "m", durationSeconds: -5).durationSeconds == 0)
    }

    @MainActor
    @Test("端到端:脚本化 Agent 回合结束后追加结束语条目,含 usage")
    func endToEnd() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("你好")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .turnSummary } })
        let summary = try #require(model.timeline.entries.last { $0.kind == .turnSummary }?.summary)
        #expect(summary.usage?.outputTokens == 360)
        #expect(model.timeline.entries.last?.kind == .turnSummary, "结束语是本轮最后一条")
        model.shutdown()
    }

    @MainActor
    @Test("取消的回合不追加结束语")
    func cancelledHasNoSummary() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("#demo-states-frozen")
        #expect(await SessionModelTests.wait { model.isRunning && !model.timeline.entries.isEmpty })
        model.cancel()
        #expect(await SessionModelTests.wait { !model.isRunning })
        #expect(!model.timeline.entries.contains { $0.kind == .turnSummary })
        model.shutdown()
    }
}
