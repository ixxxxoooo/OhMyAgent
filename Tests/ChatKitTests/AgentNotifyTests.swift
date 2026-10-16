// @author ixxxxoooo
// Agent 通知(pi-acp notify)与回合提前结束启发式的测试。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("Agent 通知与提前结束")
struct AgentNotifyTests {
    @Test("info 通知成为淡色独立行,不并入助手正文")
    func notifyIsMutedSeparateEntry() {
        UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showAgentNotify)
        let store = TimelineStore()
        store.apply(.agentMessageChunk(messageId: "m", content: .text("正文")))
        store.apply(.agentNotify(level: "info", text: "TPS 40 tok/s"))
        #expect(store.entries.count == 2)
        #expect(store.entries[0].kind == .assistant)
        #expect(store.entries[0].text == "正文")
        #expect(store.entries[1].kind == .notice)
        #expect(store.entries[1].isMuted)
    }

    @Test("设置隐藏后 info 通知不进入时间线,warning 仍显示")
    func hiddenByPreference() {
        UserDefaults.standard.set(false, forKey: ClientPrefs.Key.showAgentNotify)
        defer { UserDefaults.standard.removeObject(forKey: ClientPrefs.Key.showAgentNotify) }
        let store = TimelineStore()
        store.apply(.agentNotify(level: "info", text: "TPS 40 tok/s"))
        #expect(store.entries.isEmpty)
        store.apply(.agentNotify(level: "warning", text: "上下文即将耗尽"))
        #expect(store.entries.count == 1)
        #expect(!store.entries[0].isMuted)
        #expect(store.entries[0].severity == "warning")
    }

    @Test("非 Claude 的回合停在工具调用之后判为疑似提前结束")
    func truncatedHeuristics() {
        #expect(TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .tool))
        #expect(TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .thought))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: .assistant))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: true, reason: .endTurn, lastKind: .tool))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .cancelled, lastKind: .tool))
        #expect(!TurnEndHeuristics.looksTruncated(isClaude: false, reason: .endTurn, lastKind: nil))
    }
}

@Suite("上下文优化建议与 MCP 按需加载")
struct ContextAdvisorTests {
    private func usage(mcp: Int, total: Int, max: Int = 200_000) -> ContextUsage {
        ContextUsage(totalTokens: total, maxTokens: max, categories: [
            ContextCategory(name: "System prompt", tokens: 2_000, kind: .used),
            ContextCategory(name: "MCP tools", tokens: mcp, kind: .used),
            ContextCategory(name: "Free space", tokens: max - total, kind: .free),
        ])
    }

    @Test("MCP 工具占比超过窗口 10% 才给出建议")
    func mcpThreshold() {
        #expect(ContextAdvisor.hints(for: usage(mcp: 25_000, total: 30_000)) == [.mcpHeavy(percent: 13)])
        #expect(ContextAdvisor.hints(for: usage(mcp: 20_000, total: 30_000)).isEmpty)   // 恰好 10% 不触发
        #expect(ContextAdvisor.hints(for: usage(mcp: 5_000, total: 30_000)).isEmpty)
    }

    @Test("总占用接近上限时提示压缩;窗口无效时无建议")
    func nearFull() {
        #expect(ContextAdvisor.hints(for: usage(mcp: 0, total: 170_000)) == [.nearFull(percent: 85)])
        #expect(ContextAdvisor.hints(for: ContextUsage(totalTokens: 10, maxTokens: 0)).isEmpty)
    }

    @Test("MCP 按需加载:auto 不注入,on/off 注入 ENABLE_TOOL_SEARCH")
    func toolSearchEnvironment() {
        var options = SessionOptions()
        #expect(options.environment["ENABLE_TOOL_SEARCH"] == nil)
        options.mcpToolSearch = .on
        #expect(options.environment["ENABLE_TOOL_SEARCH"] == "true")
        options.mcpToolSearch = .off
        #expect(options.environment["ENABLE_TOOL_SEARCH"] == "false")
        #expect(!options.isDefault)
    }

    @Test("提供商已显式设置的 ENABLE_TOOL_SEARCH 优先于客户端偏好")
    func providerWins() throws {
        var options = SessionOptions()
        options.mcpToolSearch = .on
        let base: JSONValue = ["claudeCode": ["options": ["env": ["ENABLE_TOOL_SEARCH": "false"]]]]
        let merged = try #require(options.merged(into: base))
        #expect(merged["claudeCode"]?["options"]?["env"]?["ENABLE_TOOL_SEARCH"]?.stringValue == "false")
    }

    @Test("从偏好读取:未知值回退自动")
    func fromDefaults() throws {
        let suite = try #require(UserDefaults(suiteName: "oma-test-\(UUID().uuidString)"))
        suite.set("on", forKey: ClientPrefs.Key.mcpToolSearch)
        #expect(SessionOptions(defaults: suite).mcpToolSearch == .on)
        suite.set("乱写", forKey: ClientPrefs.Key.mcpToolSearch)
        #expect(SessionOptions(defaults: suite).mcpToolSearch == .auto)
    }
}
