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

    @Test("token 明细:新增与缓存读分开、不加总;悬停明细含总计、计费折合与命中率;无缓存时不显示命中率")
    func tokenDetail() throws {
        let usage = TurnUsage(inputTokens: 100, outputTokens: 50, cachedReadTokens: 800, cachedWriteTokens: 100)
        let summary = TurnSummary(model: "m", durationSeconds: 5, usage: usage)
        #expect(summary.inputTotal == 1000)
        #expect(summary.cacheHitRate == 0.8)
        #expect(summary.freshInput == 200)
        // 100 + 1.25×100 + 0.1×800 + 5×50 = 555
        #expect(summary.billedEquivalent == 555)
        #expect(summary.parts.contains { $0.contains("新增 200") && $0.contains("缓存读 800") && $0.contains("输出 50") })
        #expect(!summary.parts.contains { $0.contains("1,050") })
        #expect(summary.parts.contains { $0.contains("80%") })
        let detail = try #require(summary.tokenDetail)
        #expect(detail.contains("800") && detail.contains("1,050") && detail.contains("555") && detail.contains("80%"))
        #expect(summary.copyText.contains(detail))
        let plain = TurnSummary(model: "m", durationSeconds: 5, usage: TurnUsage(inputTokens: 100, outputTokens: 50))
        #expect(plain.cacheHitRate == nil)
        #expect(!plain.parts.contains { $0.contains("缓存") })
        #expect(plain.parts.contains { $0.contains("输入 100") && $0.contains("输出 50") })
        #expect(TurnSummary(model: "m", durationSeconds: 5).tokenDetail == nil)
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
        #expect((summary.brand != nil) == !summary.model.isEmpty, "有模型名就带厂商图标线索")
        #expect(await SessionModelTests.wait { model.timeline.entries.last?.kind == .turnSummary }, "结束语是本轮最后一条,实际尾部:\(model.timeline.entries.suffix(3).map { "\($0.kind)" })")
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

    @Test("厂商线索默认用模型 ID 兜底提供商名")
    func brandHintDefaults() {
        let hint = ModelBrandHint(modelId: "glm-5")
        #expect(hint.providerName == "glm-5")
        #expect(hint.providerPreset == nil)
        let summary = TurnSummary(model: "GLM 5", durationSeconds: 1, brand: hint)
        #expect(summary.brand == hint)
    }

    @MainActor
    @Test("结束行记录本轮助手输出:只含最近一轮,多条消息以空行连接")
    func outputTextCollectsLatestTurn() {
        let store = TimelineStore()
        store.appendUser("第一问")
        store.apply(.agentMessageChunk(messageId: "a1", content: .text("第一答")))
        store.appendTurnSummary(TurnSummary(model: "m", durationSeconds: 1))
        store.appendUser("第二问")
        store.apply(.agentMessageChunk(messageId: "a2", content: .text("第二答上")))
        store.apply(.agentThoughtChunk(messageId: "t", content: .text("思考不计入")))
        store.apply(.agentMessageChunk(messageId: "a3", content: .text("第二答下")))
        store.appendTurnSummary(TurnSummary(model: "m", durationSeconds: 1))
        #expect(store.entries.first { $0.kind == .turnSummary }?.summary?.outputText == "第一答")
        #expect(store.entries.last?.summary?.outputText == "第二答上\n\n第二答下")
    }

    @MainActor
    @Test("没有助手输出时结束行的输出正文为空")
    func outputTextEmpty() {
        let store = TimelineStore()
        store.appendUser("问")
        store.appendTurnSummary(TurnSummary(model: "m", durationSeconds: 1))
        #expect(store.entries.last?.summary?.outputText.isEmpty == true)
    }
}
