// @author ygw
// 上下文用量:`/context` 输出解析(来自真实抓取的格式)、token 简写、圆环色调、兜底分类,
// 以及会话层探测(拦截输出、不进时间线)。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("上下文用量解析")
struct ContextUsageParserTests {
    /// 真实抓取的 Claude `/context` 输出(节选)。
    static let sample = """
    ## Context Usage

    **Model:** claude-opus-5-5  
    **Tokens:** 38.6k / 1m (4%)

    ### Estimated usage by category

    | Category | Tokens | Percentage |
    |----------|--------|------------|
    | System prompt | 1.9k | 0.2% |
    | System tools | 34.7k | 3.5% |
    | Skills | 2k | 0.2% |
    | Free space | 928.4k | 92.8% |
    | Autocompact buffer | 33k | 3.3% |

    ### Skills

    | Skill | Source | Tokens |
    |-------|--------|--------|
    | dataviz | Built-in | ~480 |
    """

    @Test("解析模型、总量、窗口与分类,并识别剩余/压缩预留")
    func parsesSample() throws {
        let usage = try #require(ContextUsageParser.parse(Self.sample))
        #expect(usage.model == "claude-opus-5-5")
        #expect(usage.totalTokens == 38_600)
        #expect(usage.maxTokens == 1_000_000)
        #expect(usage.percent == 4)
        #expect(usage.categories.map(\.name) == ["System prompt", "System tools", "Skills", "Free space", "Autocompact buffer"])
        #expect(usage.categories.map(\.kind) == [.used, .used, .used, .free, .buffer])
        #expect(usage.categories[1].tokens == 34_700)
    }

    @Test("只取分类表,不把后面的 Skills 明细表混进来")
    func stopsAtNextSection() throws {
        let usage = try #require(ContextUsageParser.parse(Self.sample))
        #expect(!usage.categories.contains { $0.name == "dataviz" })
    }

    @Test("格式不符返回 nil:缺总量、缺分类表、窗口为 0")
    func rejectsMalformed() {
        #expect(ContextUsageParser.parse("") == nil)
        #expect(ContextUsageParser.parse("**Tokens:** 1k / 2k (50%)") == nil)
        #expect(ContextUsageParser.parse("### Estimated usage by category\n| A | 1k | 1% |") == nil)
        #expect(ContextUsageParser.parse("**Tokens:** 1k / 0 (0%)\n### Estimated usage by category\n| A | 1k | 1% |") == nil)
    }

    @Test("token 简写:k/m 后缀、波浪号、千分位、非法输入")
    func tokenCounts() {
        #expect(ContextUsageParser.parseTokenCount("1.9k") == 1_900)
        #expect(ContextUsageParser.parseTokenCount("1m") == 1_000_000)
        #expect(ContextUsageParser.parseTokenCount("~480") == 480)
        #expect(ContextUsageParser.parseTokenCount("1,200") == 1_200)
        #expect(ContextUsageParser.parseTokenCount("512") == 512)
        #expect(ContextUsageParser.parseTokenCount("Tokens") == nil)
        #expect(ContextUsageParser.parseTokenCount("---") == nil)
        #expect(ContextUsageParser.parseTokenCount("") == nil)
    }
}

@Suite("上下文用量模型")
struct ContextUsageModelTests {
    @Test("圆环色调:80% 起警告,95% 起危险")
    func tones() {
        #expect(ContextTone(fraction: 0.5) == .normal)
        #expect(ContextTone(fraction: 0.8) == .warn)
        #expect(ContextTone(fraction: 0.949) == .warn)
        #expect(ContextTone(fraction: 0.95) == .danger)
        #expect(ContextTone(fraction: 1.4) == .danger)
    }

    @Test("紧凑 token 格式化")
    func formatting() {
        #expect(ContextUsage.formatTokens(0) == "0")
        #expect(ContextUsage.formatTokens(999) == "999")
        #expect(ContextUsage.formatTokens(2_400) == "2.4K")
        #expect(ContextUsage.formatTokens(10_000) == "10K")
        #expect(ContextUsage.formatTokens(300_000) == "300K")
        #expect(ContextUsage.formatTokens(1_200_000) == "1.2M")
    }

    @Test("由 Agent 上报的已用/窗口合成已用+剩余两段;缺数据时为 nil")
    func syntheticFromReported() throws {
        let usage = try #require(ContextUsage(reported: UsageUpdate(used: 50, size: 200)))
        #expect(usage.fraction == 0.25)
        #expect(usage.categories.map(\.kind) == [.used, .free])
        #expect(usage.categories.map(\.tokens) == [50, 150])
        #expect(ContextUsage(reported: UsageUpdate(used: 50, size: nil)) == nil)
        #expect(ContextUsage(reported: UsageUpdate(used: 50, size: 0)) == nil)
        #expect(ContextUsage(reported: UsageUpdate()) == nil)
    }

    @Test("已用超过窗口时剩余不为负,占比可超过 100%")
    func overflow() throws {
        let usage = try #require(ContextUsage(reported: UsageUpdate(used: 300, size: 200)))
        #expect(usage.categories.last?.tokens == 0)
        #expect(usage.percent == 150)
    }
}

@MainActor
@Suite("上下文明细探测(会话层)")
struct ContextProbeSessionTests {
    @Test("探测只更新明细,`/context` 的输出与命令都不进入时间线")
    func probeDoesNotPolluteTimeline() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        #expect(await SessionModelTests.wait { model.availableCommands.contains { $0.name == "context" } })
        #expect(model.supportsContextBreakdown)
        #expect(model.contextUsage == nil)

        await model.refreshContextUsage()

        let usage = try #require(model.contextUsage)
        #expect(usage.maxTokens == 200_000)
        #expect(usage.categories.contains { $0.kind == .free })
        #expect(usage.categories.contains { $0.kind == .buffer })
        #expect(model.timeline.entries.isEmpty)
        #expect(!model.isProbingContext)
        model.shutdown()
    }
}
