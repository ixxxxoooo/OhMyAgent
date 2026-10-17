// @author ixxxxoooo
// 套餐用量与提示缓存:限额解析(回复事件 / get_usage)、合并、重置文案、缓存统计与刷新状态。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@Suite("套餐用量")
@MainActor
struct PlanUsageTests {
    @Test("解析回复时的 rate_limit_event:单个窗口,utilization 已是 0...1")
    func rateLimitEvent() {
        let info: JSONValue = ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.43, "resetsAt": 1_800_000_000]
        let windows = PlanUsageParser.windows(rateLimitInfo: info)
        #expect(windows == [RateLimitWindow(id: "five_hour", label: "5-hour limit", utilization: 0.43, resetsAt: Date(timeIntervalSince1970: 1_800_000_000))])
        #expect(PlanUsageParser.windows(rateLimitInfo: ["status": "allowed"]).isEmpty)
    }

    @Test("解析 unifiedWindows:已知类型排在前面")
    func unifiedWindows() {
        let info: JSONValue = ["unifiedWindows": [
            "seven_day": ["utilization": 0.1],
            "five_hour": ["utilization": 0.5, "resetsAt": 10],
        ]]
        #expect(PlanUsageParser.windows(rateLimitInfo: info).map(\.id) == ["five_hour", "seven_day"])
    }

    @Test("解析 get_usage:百分比换算、ISO 时间(6 位小数秒)、按模型的周限额")
    func usageResponse() throws {
        let response: JSONValue = [
            "rate_limits_available": true,
            "rate_limits": [
                "five_hour": ["utilization": 47, "resets_at": "2026-10-17T19:40:00.282503+00:00"],
                "seven_day": ["utilization": 14, "resets_at": "2026-10-23T05:00:00+00:00"],
                "seven_day_opus": nil,
                "model_scoped": [["display_name": "Opus", "utilization": 30, "resets_at": nil]],
            ],
        ]
        let windows = try #require(PlanUsageParser.windows(usageResponse: response))
        #expect(windows.map(\.label) == ["5-hour limit", "Weekly limit", "Weekly Opus limit"])
        #expect(windows[0].utilization == 0.47)
        let reset = try #require(windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_792_266_000.2825) < 0.01)
        #expect(windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_731_600))
        #expect(windows[2].id == "model:Opus" && windows[2].resetsAt == nil)
    }

    @Test("get_usage:不适用为空数组,还没有限额为 nil(可重试)")
    func usageResponseStates() {
        #expect(PlanUsageParser.windows(usageResponse: ["rate_limits_available": false]) == [])
        #expect(PlanUsageParser.windows(usageResponse: ["rate_limits_available": true, "rate_limits": nil]) == nil)
    }

    @Test("合并:同类型替换并保持顺序,新类型追加")
    func merge() {
        let center = PlanUsageCenter()
        center.merge([RateLimitWindow(id: "five_hour", label: "a", utilization: 0.1), RateLimitWindow(id: "seven_day", label: "b", utilization: 0.2)])
        center.merge([RateLimitWindow(id: "seven_day_opus", label: "c", utilization: 0.3), RateLimitWindow(id: "five_hour", label: "a", utilization: 0.4)])
        #expect(center.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(center.windows[0].utilization == 0.4)
    }

    @Test("已过重置时间的窗口视为重新开始")
    func fractionAfterReset() {
        let now = Date()
        let window = RateLimitWindow(id: "five_hour", label: "", utilization: 1.4, resetsAt: now.addingTimeInterval(60))
        #expect(window.fraction(at: now) == 1)
        #expect(window.fraction(at: now.addingTimeInterval(61)) == 0)
    }

    @Test("重置文案:分钟 / 小时 / 天")
    func resetText() {
        let now = Date(timeIntervalSince1970: 0)
        func text(_ seconds: Double) -> String? { PlanResetText.text(until: now.addingTimeInterval(seconds), now: now) }
        #expect(text(46 * 60 + 5) == "46分钟后重置")
        #expect(text(2 * 3600) == "2小时后重置")
        #expect(text(90 * 60) == "1小时30分钟后重置")
        #expect(text(3 * 86_400) == "3天后重置")
        #expect(text((5 * 24 + 10) * 3600) == "5天10小时后重置")
        #expect(text(-1) == nil)
    }

    @Test("刷新:关闭非必要流量时不获取;失败为 unavailable;成功后 30 秒内复用")
    func refreshStates() async {
        let center = PlanUsageCenter()
        await center.refresh(offBy: PlanUsageProbe.essentialTrafficVariable) { [] }
        #expect(center.state == .off)
        await center.refresh(offBy: nil) { nil }
        #expect(center.state == .unavailable)
        await center.refresh(offBy: nil) { [RateLimitWindow(id: "five_hour", label: "5-hour limit", utilization: 0.2)] }
        #expect(center.state == .idle && center.windows.count == 1)
        await center.refresh(offBy: nil) { [RateLimitWindow(id: "seven_day", label: "Weekly limit", utilization: 0.2)] }
        #expect(center.windows.count == 1)
    }

    @Test("关闭开关只认非空的环境变量")
    func offBy() {
        #expect(PlanUsageProbe.offBy(environment: [:]) == nil)
        #expect(PlanUsageProbe.offBy(environment: [PlanUsageProbe.essentialTrafficVariable: ""]) == nil)
        #expect(PlanUsageProbe.offBy(environment: [PlanUsageProbe.essentialTrafficVariable: "1"]) == PlanUsageProbe.essentialTrafficVariable)
    }

    @Test("提示缓存:累计主对话,无缓存读写的轮次不计入")
    func promptCache() throws {
        var stats = PromptCacheStats.recording(TurnUsage(inputTokens: 100, cachedReadTokens: 900, cachedWriteTokens: 0), onto: nil)
        #expect(stats?.last.hitPercent == 90)
        stats = PromptCacheStats.recording(TurnUsage(inputTokens: 50, cachedReadTokens: 0, cachedWriteTokens: 0), onto: stats)
        #expect(stats?.last.hitPercent == 90)
        stats = PromptCacheStats.recording(TurnUsage(inputTokens: 0, cachedReadTokens: 500, cachedWriteTokens: 500), onto: stats)
        let value = try #require(stats)
        #expect(value.last == CacheTokens(read: 500, written: 500, uncached: 0))
        #expect(value.conversation == CacheTokens(read: 1400, written: 500, uncached: 100))
        #expect(PromptCacheStats.recording(TurnUsage(inputTokens: 10), onto: nil) == nil)
    }

    @Test("usage_update 的 _meta 携带限额事件")
    func usageUpdateMeta() {
        let update = SessionUpdate(json: ["sessionUpdate": "usage_update", "used": 1, "size": 2, "_meta": ["_claude/rateLimit": ["rateLimitType": "seven_day", "utilization": 0.5]]])
        guard case .usage(let usage) = update else {
            Issue.record("应解析为 usage")
            return
        }
        #expect(usage.rateLimit?["rateLimitType"]?.stringValue == "seven_day")
        #expect(usage.costAmount == nil)
    }
}
