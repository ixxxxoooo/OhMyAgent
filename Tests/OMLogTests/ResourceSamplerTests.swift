// @author ixxxxoooo
// 资源采样器测试:CPU 差分、增长/绝对值/CPU 告警、子进程聚合与清理、容量快照、真实探针冒烟。

import Foundation
import Synchronization
import Testing
@testable import OMLog

/// 可编程的假探针。
private final class FakeProbe: ResourceProbing, @unchecked Sendable {
    private let usages = Mutex<[Int32: ProcessUsage]>([:])
    func set(_ pid: Int32, footprintMB: Double, cpuSeconds: Double) {
        usages.withLock {
            $0[pid] = ProcessUsage(footprintBytes: UInt64(footprintMB * 1_048_576), peakFootprintBytes: UInt64(footprintMB * 1_048_576), cpuNanos: UInt64(cpuSeconds * 1e9))
        }
    }
    func remove(_ pid: Int32) { usages.withLock { _ = $0.removeValue(forKey: pid) } }
    func usage(pid: Int32) -> ProcessUsage? { usages.withLock { $0[pid] } }
    func threadCount(pid: Int32) -> Int? { 12 }
    func openFileCount(pid: Int32) -> Int? { 34 }
}

private struct Rig {
    let probe = FakeProbe()
    let registry = ProcessRegistry()
    let gauges = GaugeRegistry()
    let stats = PerfStats()
    let system = LogSystem(level: .debug, osLog: false)
    let sampler: ResourceSampler

    init(thresholds: ResourceThresholds = ResourceThresholds()) {
        let probe = self.probe, registry = self.registry, gauges = self.gauges, stats = self.stats
        let logger = OMLogger(.perf, system: system)
        sampler = ResourceSampler(probe: probe, registry: registry, gauges: gauges, stats: stats, logger: logger, selfPID: 100, thresholds: thresholds)
    }

    func lines(_ keyword: String) -> [String] { system.recent().map(\.line).filter { $0.contains(keyword) } }
}

@Suite("资源采样器")
struct ResourceSamplerTests {
    @Test("首次采样无 CPU 百分比,之后按累计 CPU 时间差分")
    func cpuDelta() throws {
        let rig = Rig()
        let t0 = ContinuousClock.now
        rig.probe.set(100, footprintMB: 100, cpuSeconds: 10)
        let first = try #require(rig.sampler.sample(now: t0))
        #expect(first.cpuPercent == nil)
        rig.probe.set(100, footprintMB: 100, cpuSeconds: 15)  // 10 秒内用了 5 秒 CPU
        let second = try #require(rig.sampler.sample(now: t0 + .seconds(10)))
        #expect(abs(try #require(second.cpuPercent) - 50) < 0.5)
        #expect(second.threads == 12 && second.fds == 34)
    }

    @Test("子进程按角色聚合,退出的进程自动注销")
    func children() throws {
        let rig = Rig()
        rig.probe.set(100, footprintMB: 100, cpuSeconds: 0)
        rig.probe.set(201, footprintMB: 300, cpuSeconds: 0)
        rig.probe.set(202, footprintMB: 100, cpuSeconds: 0)
        rig.probe.set(301, footprintMB: 50, cpuSeconds: 0)
        rig.registry.register(pid: 201, role: .agent, label: "claude")
        rig.registry.register(pid: 202, role: .agent, label: "node")
        rig.registry.register(pid: 301, role: .lsp, label: "sourcekit-lsp")
        let sample = try #require(rig.sampler.sample())
        #expect(sample.children.count == 3)
        #expect(sample.childrenFootprintMB == 450)
        let line = try #require(rig.lines("资源采样").last)
        #expect(line.contains("agentCount=2") && line.contains("agentMB=400.0"))
        #expect(line.contains("lspCount=1") && line.contains("lspMB=50.0"))
        #expect(!line.contains("terminalCount"))

        rig.probe.remove(202)  // 进程已消失但漏了注销
        let after = try #require(rig.sampler.sample())
        #expect(after.children.count == 2)
        #expect(rig.registry.snapshot().map(\.pid) == [201, 301])
    }

    @Test("相邻采样增长超过阈值记 warning 并附容量快照")
    func growthWarning() {
        var thresholds = ResourceThresholds()
        thresholds.warmupSeconds = 0
        let rig = Rig(thresholds: thresholds)
        rig.gauges.register("timeline.entries") { 1234 }
        rig.probe.set(100, footprintMB: 100, cpuSeconds: 0)
        rig.sampler.sample()
        #expect(rig.lines("内存增长较快").isEmpty)
        rig.probe.set(100, footprintMB: 180, cpuSeconds: 0)
        rig.sampler.sample()
        let warning = rig.lines("内存增长较快")
        #expect(warning.count == 1)
        #expect(warning[0].contains("deltaMB=80.0"))
        #expect(warning[0].contains("timeline.entries=1234"))
        #expect(rig.lines("容量快照").count == 2)
    }

    @Test("预热窗口内的增长不告警,窗口过后恢复")
    func warmup() {
        let rig = Rig()  // 默认预热 60 秒
        let t0 = ContinuousClock.now
        rig.probe.set(100, footprintMB: 5, cpuSeconds: 0)
        rig.sampler.sample(now: t0)
        rig.probe.set(100, footprintMB: 120, cpuSeconds: 0)
        rig.sampler.sample(now: t0 + .seconds(30))
        #expect(rig.lines("内存增长较快").isEmpty)
        rig.probe.set(100, footprintMB: 200, cpuSeconds: 0)
        rig.sampler.sample(now: t0 + .seconds(90))
        #expect(rig.lines("内存增长较快").count == 1)
    }

    @Test("绝对值告警按步长限频")
    func absoluteWarning() {
        var thresholds = ResourceThresholds()
        thresholds.absoluteWarnMB = 500
        thresholds.absoluteStepMB = 200
        thresholds.growthWarnMB = 10_000
        let rig = Rig(thresholds: thresholds)
        for mb in [400.0, 520, 540, 600, 730] {
            rig.probe.set(100, footprintMB: mb, cpuSeconds: 0)
            rig.sampler.sample()
        }
        // 520 触发;540/600 未满步长;730 ≥ 520+200 再触发
        #expect(rig.lines("内存占用偏高").count == 2)
    }

    @Test("CPU 连续偏高才告警,并附耗时 Top")
    func cpuWarning() {
        var thresholds = ResourceThresholds()
        thresholds.cpuStreak = 3
        let rig = Rig(thresholds: thresholds)
        rig.stats.record(name: "Markdown 解析", micros: 50_000)
        let t0 = ContinuousClock.now
        var cpu = 0.0
        rig.probe.set(100, footprintMB: 100, cpuSeconds: cpu)
        rig.sampler.sample(now: t0)
        for step in 1...4 {  // 每 10 秒用 8 秒 CPU = 80%
            cpu += 8
            rig.probe.set(100, footprintMB: 100, cpuSeconds: cpu)
            rig.sampler.sample(now: t0 + .seconds(10 * step))
            if step < 3 { #expect(rig.lines("CPU 持续偏高").isEmpty) }
        }
        let warnings = rig.lines("CPU 持续偏高")
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("topSpans"))
        #expect(warnings[0].contains("Markdown 解析"))
    }

    @Test("一次空闲采样会打断 CPU 连续计数")
    func cpuStreakResets() {
        let rig = Rig()
        let t0 = ContinuousClock.now
        var cpu = 0.0
        rig.probe.set(100, footprintMB: 100, cpuSeconds: cpu)
        rig.sampler.sample(now: t0)
        for (step, delta) in [8.0, 8, 0.1, 8, 8].enumerated() {
            cpu += delta
            rig.probe.set(100, footprintMB: 100, cpuSeconds: cpu)
            rig.sampler.sample(now: t0 + .seconds(10 * (step + 1)))
        }
        #expect(rig.lines("CPU 持续偏高").isEmpty)
    }

    @Test("历史有上限,峰值与次数累计")
    func historyAndTotals() {
        let rig = Rig()
        for mb in [100.0, 300, 200] {
            rig.probe.set(100, footprintMB: mb, cpuSeconds: 0)
            rig.sampler.sample()
        }
        #expect(rig.sampler.history().count == 3)
        #expect(rig.sampler.totals.peakMB == 300)
        #expect(rig.sampler.totals.samples == 3)
    }

    @Test("本进程读数失败时不崩溃并记录 warning")
    func ownFailure() {
        let rig = Rig()
        #expect(rig.sampler.sample() == nil)
        #expect(rig.lines("资源采样失败").count == 1)
    }

    @Test("采样间隔解析:环境变量 > 偏好 > 默认,并限制范围")
    func interval() throws {
        let suite = "oma-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: [:]) == 30)
        defaults.set(60, forKey: ResourceSampler.intervalDefaultsKey)
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: [:]) == 60)
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: ["OMA_PERF_SAMPLE_SECONDS": "10"]) == 10)
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: ["OMA_PERF_SAMPLE_SECONDS": "1"]) == 5)
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: ["OMA_PERF_SAMPLE_SECONDS": "0"]) == 0)
        #expect(ResourceSampler.configuredInterval(defaults: defaults, environment: ["OMA_PERF_SAMPLE_SECONDS": "99999"]) == 600)
    }

    @Test("真实探针能读到本进程的占用、线程与文件描述符")
    func systemProbe() throws {
        let probe = SystemResourceProbe()
        let pid = ProcessInfo.processInfo.processIdentifier
        let usage = try #require(probe.usage(pid: pid))
        #expect(usage.footprintBytes > 1_000_000)
        #expect(usage.peakFootprintBytes >= usage.footprintBytes / 2)
        #expect(usage.cpuNanos > 0)
        #expect((probe.threadCount(pid: pid) ?? 0) >= 1)
        #expect((probe.openFileCount(pid: pid) ?? 0) >= 3)
        #expect(probe.usage(pid: 0x7fff_fff0) == nil)
    }
}

@Suite("登记表与容量指标")
struct RegistryTests {
    @Test("进程登记、重复登记覆盖、非法 pid 忽略、注销")
    func processRegistry() {
        let registry = ProcessRegistry()
        registry.register(pid: 5, role: .agent, label: "a")
        registry.register(pid: 5, role: .lsp, label: "b")
        registry.register(pid: 0, role: .agent, label: "bad")
        registry.register(pid: -3, role: .agent, label: "bad")
        #expect(registry.snapshot() == [ProcessRegistry.Entry(pid: 5, role: .lsp, label: "b")])
        registry.unregister(pid: 5)
        registry.unregister(pid: 99)
        #expect(registry.snapshot().isEmpty)
    }

    @Test("容量指标按需读取,可替换与注销,读取闭包内可反向注册")
    func gauges() {
        let gauges = GaugeRegistry()
        let counter = Mutex(0)
        gauges.register("a") { counter.withLock { $0 += 1; return $0 } }
        gauges.register("b") { gauges.register("c") { 1 }; return 0 }  // 读取闭包里反向注册不应死锁
        #expect(counter.withLock { $0 } == 0)  // 注册时不调用
        _ = gauges.snapshot()
        #expect(counter.withLock { $0 } == 1)
        gauges.register("a") { 42 }
        gauges.unregister("b")
        gauges.unregister("c")
        #expect(gauges.snapshot() == ["a": 42])
    }
}

@Suite("积压计数与主线程指标")
struct BacklogTests {
    @Test("积压深度与峰值")
    func backlog() {
        let backlog = StreamBacklog(name: "t.backlog", registry: nil)
        backlog.produced(5)
        backlog.consumed(2)
        #expect(backlog.depth == 3)
        backlog.produced(10)
        #expect(backlog.peak == 13)
        backlog.consumed(100)  // 多消费不出现负数
        #expect(backlog.depth == 0)
        #expect(backlog.peak == 13)
    }

    @Test("积压计数自动注册为深度与峰值两个指标")
    func registered() {
        let gauges = GaugeRegistry()
        let backlog = StreamBacklog(name: "t.reg", registry: gauges)
        backlog.produced(4)
        backlog.consumed(1)
        #expect(gauges.snapshot() == ["t.reg.depth": 3, "t.reg.peak": 4])
    }

    @Test("主 actor 指标只在 refreshMain 后可见,注销后消失")
    @MainActor
    func mainGauges() {
        let gauges = GaugeRegistry()
        var value = 7
        gauges.registerMain("m") { value }
        #expect(gauges.snapshot().isEmpty)
        gauges.refreshMain()
        #expect(gauges.snapshot() == ["m": 7])
        value = 9
        #expect(gauges.snapshot() == ["m": 7])  // 未刷新仍是旧值
        gauges.refreshMain()
        #expect(gauges.snapshot() == ["m": 9])
        gauges.unregister("m")
        #expect(gauges.snapshot().isEmpty)
    }
}
