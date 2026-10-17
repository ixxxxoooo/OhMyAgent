// @author ixxxxoooo
// 性能观测基础设施测试:耗时聚合与分位数、名称上限、按分类级别、关联标识、跨度与计时口径。

import Foundation
import Testing
@testable import OMLog

@Suite("耗时聚合 PerfStats")
struct PerfStatsTests {
    @Test("次数、累计、最大值与分位数")
    func aggregates() {
        let stats = PerfStats()
        // 90 次 1ms,10 次 100ms
        for _ in 0..<90 { stats.record(name: "解析", micros: 1_000) }
        for _ in 0..<10 { stats.record(name: "解析", micros: 100_000) }
        let row = try! #require(stats.snapshot().first)
        #expect(row.name == "解析")
        #expect(row.count == 100)
        #expect(row.totalMs == 1090)
        #expect(row.maxMs == 100)
        #expect(row.p50Ms == 1)
        #expect(row.p95Ms == 100)  // 落入 (64,128] 桶,上界 128 被钳到观测最大值 100
        #expect(row.p95Ms >= row.p50Ms)
    }

    @Test("分位数不超过观测最大值,亚毫秒耗时不丢失")
    func clampedToMax() {
        let stats = PerfStats()
        stats.record(name: "快", micros: 300)
        let row = try! #require(stats.snapshot().first)
        #expect(row.p95Ms <= row.maxMs)
        #expect(row.totalMs > 0)
    }

    @Test("按累计耗时降序,top 截断")
    func sortedAndTrimmed() {
        let stats = PerfStats()
        stats.record(name: "a", micros: 1_000)
        stats.record(name: "b", micros: 9_000)
        stats.record(name: "c", micros: 5_000)
        #expect(stats.snapshot(top: 2).map(\.name) == ["b", "c"])
    }

    @Test("跨度名超过上限后归入「其他」,已有名字继续累计")
    func nameCap() {
        let stats = PerfStats(maxNames: 2)
        stats.record(name: "a", micros: 1_000)
        stats.record(name: "b", micros: 1_000)
        stats.record(name: "c", micros: 1_000)
        stats.record(name: "a", micros: 1_000)
        let rows = Dictionary(uniqueKeysWithValues: stats.snapshot().map { ($0.name, $0.count) })
        #expect(rows["a"] == 2)
        #expect(rows["b"] == 1)
        #expect(rows[PerfStats.overflowName] == 1)
        #expect(rows["c"] == nil)
    }

    @Test("负数按 0 处理,reset 清空")
    func negativeAndReset() {
        let stats = PerfStats()
        stats.record(name: "x", micros: -5)
        #expect(stats.snapshot().first?.totalMs == 0)
        stats.reset()
        #expect(stats.snapshot().isEmpty)
    }

    @Test("并发写入不丢计数")
    func concurrent() async {
        let stats = PerfStats()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<500 { stats.record(name: "c", micros: 10) } } }
        }
        #expect(stats.snapshot().first?.count == 4000)
    }

    @Test("汇总日志每个跨度一行并带统计字段")
    func summaryLog() {
        let system = LogSystem(level: .info, osLog: false)
        let stats = PerfStats()
        stats.record(name: "保存", micros: 20_000)
        stats.logSummary(to: OMLogger(.perf, system: system))
        let line = try! #require(system.recent().last).line
        #expect(line.contains("性能汇总"))
        #expect(line.contains("name=保存"))
        #expect(line.contains("count=1"))
        #expect(line.contains("totalMs=20.0"))
    }
}

@Suite("按分类日志级别")
struct CategoryLevelTests {
    @Test("分类覆盖优先于全局,清除后恢复")
    func override() {
        let system = LogSystem(level: .warning, osLog: false)
        let perf = OMLogger(.perf, system: system)
        let app = OMLogger(.app, system: system)
        system.setLevel(.debug, for: .perf)
        perf.debug("看得到")
        app.debug("看不到")
        #expect(system.recent().count == 1)
        #expect(system.level(for: .perf) == .debug)
        #expect(system.level(for: .app) == .warning)
        system.setLevel(nil, for: .perf)
        perf.debug("又看不到")
        #expect(system.recent().count == 1)
    }

    @Test("环境变量与偏好都能设置分类级别,环境变量优先")
    func configuration() throws {
        let suite = "oma-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("error", forKey: "log.level.perf")
        defaults.set("debug", forKey: "log.level.git")
        let system = LogSystem(level: .info, osLog: false)
        system.loadConfiguration(defaults: defaults, environment: ["OMA_LOG_LEVEL_PERF": "debug"])
        #expect(system.level(for: .perf) == .debug)
        #expect(system.level(for: .git) == .debug)
        #expect(system.level(for: .acp) == .info)
    }
}

@Suite("关联标识")
struct CorrelationIDTests {
    @Test("会话缩写为前 8 位,回合带 t 前缀")
    func formats() {
        #expect(CorrelationID.session("0123456789abcdef") == "01234567")
        #expect(CorrelationID.session("") == "-")
        #expect(CorrelationID.turn(12) == "t12")
        #expect(CorrelationID.turn(-1) == "t0")
    }

    @Test("correlated 只写入非空项且字段名统一")
    func fields() {
        let system = LogSystem(level: .info, osLog: false)
        OMLogger(.session, system: system)
            .correlated(session: "0123456789abcdef", turn: 3, toolCall: "tc1")
            .info("事件")
        let line = try! #require(system.recent().last).line
        #expect(line.contains("sid=01234567"))
        #expect(line.contains("turn=t3"))
        #expect(line.contains("tcid=tc1"))
        #expect(!line.contains("req="))
    }
}

@Suite("耗时跨度")
struct PerfSpanTests {
    @Test("跨度结束写入聚合并返回毫秒,timed 同步与异步都记录")
    func spanAndTimed() async {
        let name = "测试跨度-\(UUID().uuidString)"
        let logger = OMLogger(.perf, system: LogSystem(level: .debug, osLog: false))
        let span = logger.span(name, warnMs: 10_000)
        let ms = span.end()
        #expect(ms >= 0)
        let value = logger.timed(name + "-sync", warnMs: 10_000) { 7 }
        let asyncValue = await logger.timed(name + "-async", warnMs: 10_000) { 8 }
        #expect(value == 7 && asyncValue == 8)
        let names = Set(PerfStats.shared.snapshot(top: 1000).map(\.name))
        #expect(names.contains(name))
        #expect(names.contains(name + "-sync"))
        #expect(names.contains(name + "-async"))
    }

    @Test("超过阈值记 warning,quiet 低于阈值不落日志")
    func thresholds() {
        let system = LogSystem(level: .debug, osLog: false)
        let logger = OMLogger(.perf, system: system)
        logger.span("安静", warnMs: 10_000, quiet: true).end()
        #expect(system.recent().isEmpty)
        logger.span("总是慢", warnMs: 0).end()
        #expect(system.recent().last?.level == .warning)
    }

    @Test("微秒与毫秒计时口径一致")
    func clock() {
        let start = ContinuousClock.now - .milliseconds(1500)
        let micros = OMLogger.microseconds(since: start)
        let ms = OMLogger.milliseconds(since: start)
        #expect(micros >= 1_500_000)
        #expect(ms >= 1500 && ms < 1600)
    }

    @Test("卡顿监视器统计初始为零")
    func hitchTotals() {
        #expect(MainThreadHitchMonitor.shared.totals.count >= 0)
    }
}
