// @author ixxxxoooo
// 资源采样器:周期性记录本进程与已登记子进程的内存(phys_footprint)、CPU%、线程与文件描述符,
// 并在内存快速增长、绝对值过高、CPU 持续偏高时升级为 warning 且附带容量快照与耗时 Top,
// 让「内存/CPU 花在哪」事后只看日志就能判断,不依赖当时是否开着活动监视器。

import Foundation
import Synchronization

/// 单次资源采样结果。
public struct ResourceSample: Sendable, Equatable {
    /// 一个子进程的读数。
    public struct Child: Sendable, Equatable {
        public let pid: Int32
        public let role: ProcessRole
        public let label: String
        public let footprintMB: Double
        /// 自上次采样以来的 CPU 占用百分比(单核 100%);首次采样为 nil。
        public let cpuPercent: Double?
    }

    public let date: Date
    /// 本进程当前占用(MB)。
    public let footprintMB: Double
    /// 本进程生命周期内占用峰值(MB)。
    public let peakMB: Double
    /// 本进程 CPU 占用百分比(单核 100%);首次采样为 nil。
    public let cpuPercent: Double?
    public let threads: Int
    public let fds: Int
    public let children: [Child]

    /// 子进程占用合计(MB)。
    public var childrenFootprintMB: Double { children.reduce(0) { $0 + $1.footprintMB } }
}

/// 告警阈值。
public struct ResourceThresholds: Sendable, Equatable {
    /// 相邻两次采样间本进程占用增长超过该 MB 数,记为「增长较快」。
    public var growthWarnMB: Double = 50
    /// 本进程占用超过该 MB 数开始告警;之后仅当再增长 `absoluteStepMB` 才再次告警。
    public var absoluteWarnMB: Double = 800
    /// 绝对值告警的再触发步长(MB)。
    public var absoluteStepMB: Double = 256
    /// CPU 占用超过该百分比计入「偏高」。
    public var cpuWarnPercent: Double = 60
    /// 连续多少次采样偏高才告警。
    public var cpuStreak: Int = 3
    /// 预热窗口(秒):自首次采样起这段时间内不报「增长较快」,避免把启动期的正常增长当成异常。
    public var warmupSeconds: Double = 60

    public init() {}
}

/// 资源采样器(线程安全;`sample()` 可直接调用,便于测试)。
public final class ResourceSampler: @unchecked Sendable {
    public static let shared = ResourceSampler()

    /// UserDefaults 键:采样间隔(秒),0 表示关闭。
    public static let intervalDefaultsKey = "perf.sampleInterval"
    /// 默认采样间隔(秒)。
    public static let defaultInterval = 30

    private struct CPUMark {
        var nanos: UInt64
        var at: ContinuousClock.Instant
    }

    private struct State {
        var selfMark: CPUMark?
        var firstSampleAt: ContinuousClock.Instant?
        var childMarks: [Int32: CPUMark] = [:]
        var lastFootprintMB: Double?
        var lastAbsoluteWarnMB: Double = 0
        var cpuHighStreak = 0
        var peakMB: Double = 0
        var count = 0
        var history: [ResourceSample] = []
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let probe: any ResourceProbing
    private let registry: ProcessRegistry
    private let gauges: GaugeRegistry
    private let stats: PerfStats
    private let logger: OMLogger
    private let selfPID: Int32
    private let historyCapacity = 240
    /// 告警阈值(可在启动前调整)。
    public let thresholds: ResourceThresholds

    /// 创建采样器。
    /// - Parameters:
    ///   - probe: 资源探针
    ///   - registry: 子进程登记表
    ///   - gauges: 容量指标注册表
    ///   - stats: 耗时聚合器(CPU 告警时附带 Top 耗时)
    ///   - logger: 输出日志器
    ///   - selfPID: 本进程号
    ///   - thresholds: 告警阈值
    public init(
        probe: any ResourceProbing = SystemResourceProbe(),
        registry: ProcessRegistry = .shared,
        gauges: GaugeRegistry = .shared,
        stats: PerfStats = .shared,
        logger: OMLogger = Log.perf,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        thresholds: ResourceThresholds = ResourceThresholds()
    ) {
        self.probe = probe; self.registry = registry; self.gauges = gauges; self.stats = stats
        self.logger = logger; self.selfPID = selfPID; self.thresholds = thresholds
    }

    /// 解析采样间隔:环境变量 `OMA_PERF_SAMPLE_SECONDS` 优先,其次偏好,缺省 30 秒;0 关闭,其余限制在 5…600。
    /// - Parameters:
    ///   - defaults: 偏好存储
    ///   - environment: 环境变量
    /// - Returns: 间隔秒数,0 表示关闭
    public static func configuredInterval(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        let raw: Int
        if let text = environment["OMA_PERF_SAMPLE_SECONDS"], let value = Int(text) { raw = value }
        else if defaults.object(forKey: intervalDefaultsKey) != nil { raw = defaults.integer(forKey: intervalDefaultsKey) }
        else { raw = defaultInterval }
        return raw <= 0 ? 0 : min(max(raw, 5), 600)
    }

    /// 启动(或以新间隔重启)周期采样,立即采一次作为基线。
    /// - Parameter intervalSeconds: 间隔秒数;不大于 0 等价于停止
    public func start(intervalSeconds: Int) {
        stop()
        guard intervalSeconds > 0 else { return }
        let task = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                _ = sample()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
        state.withLock { $0.task = task }
    }

    /// 停止周期采样。
    public func stop() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
        }
    }

    /// 最近的采样结果(时间升序),供诊断页画曲线。
    public func history() -> [ResourceSample] {
        state.withLock { $0.history }
    }

    /// 自启动以来本进程占用峰值(MB)与采样次数。
    public var totals: (peakMB: Double, samples: Int) {
        state.withLock { ($0.peakMB, $0.count) }
    }

    /// 执行一次采样、写日志并返回结果。
    /// - Parameter now: 采样时刻(测试可注入以控制 CPU 百分比的时间基准)
    /// - Returns: 采样结果;本进程读数失败返回 nil
    @discardableResult
    public func sample(now: ContinuousClock.Instant = .now) -> ResourceSample? {
        guard let own = probe.usage(pid: selfPID) else {
            logger.warning("资源采样失败", ["pid": "\(selfPID)"])
            return nil
        }
        let ownMB = Self.megabytes(own.footprintBytes)
        let peakMB = max(Self.megabytes(own.peakFootprintBytes), ownMB)

        var childReadings: [(ProcessRegistry.Entry, ProcessUsage)] = []
        for entry in registry.snapshot() {
            if let usage = probe.usage(pid: entry.pid) { childReadings.append((entry, usage)) } else { registry.unregister(pid: entry.pid) }
        }

        // 在锁内只做 CPU 差分与状态更新,日志与外部读取放到锁外。
        let (cpu, children, growth, absoluteWarn, cpuWarn) = state.withLock { state -> (Double?, [ResourceSample.Child], Double?, Bool, Bool) in
            let cpu = Self.cpuPercent(mark: &state.selfMark, nanos: own.cpuNanos, now: now)
            var alive = Set<Int32>()
            let children = childReadings.map { entry, usage -> ResourceSample.Child in
                alive.insert(entry.pid)
                var mark = state.childMarks[entry.pid]
                let percent = Self.cpuPercent(mark: &mark, nanos: usage.cpuNanos, now: now)
                state.childMarks[entry.pid] = mark
                return ResourceSample.Child(pid: entry.pid, role: entry.role, label: entry.label, footprintMB: Self.megabytes(usage.footprintBytes), cpuPercent: percent)
            }
            state.childMarks = state.childMarks.filter { alive.contains($0.key) }

            let firstAt = state.firstSampleAt ?? now
            state.firstSampleAt = firstAt
            let warmup = now - firstAt < .milliseconds(Int(thresholds.warmupSeconds * 1000))
            let growth = warmup ? nil : state.lastFootprintMB.map { ownMB - $0 }
            state.lastFootprintMB = ownMB
            state.peakMB = max(state.peakMB, peakMB)
            state.count += 1

            var absoluteWarn = false
            if ownMB >= thresholds.absoluteWarnMB, ownMB >= state.lastAbsoluteWarnMB + thresholds.absoluteStepMB {
                absoluteWarn = true
                state.lastAbsoluteWarnMB = ownMB
            }

            if let cpu, cpu >= thresholds.cpuWarnPercent { state.cpuHighStreak += 1 } else { state.cpuHighStreak = 0 }
            var cpuWarn = false
            if state.cpuHighStreak >= thresholds.cpuStreak {
                cpuWarn = true
                state.cpuHighStreak = 0
            }
            return (cpu, children, growth, absoluteWarn, cpuWarn)
        }

        let result = ResourceSample(
            date: Date(), footprintMB: ownMB, peakMB: peakMB, cpuPercent: cpu,
            threads: probe.threadCount(pid: selfPID) ?? 0, fds: probe.openFileCount(pid: selfPID) ?? 0, children: children
        )
        state.withLock { state in
            state.history.append(result)
            if state.history.count > historyCapacity { state.history.removeFirst(state.history.count - historyCapacity) }
        }

        let capacity = gauges.snapshot()
        logger.info("资源采样", Self.fields(for: result))
        if !capacity.isEmpty { logger.info("容量快照", Self.gaugeFields(capacity)) }

        if let growth, growth >= thresholds.growthWarnMB {
            logger.warning("内存增长较快", Self.fields(for: result).merging(["deltaMB": Self.format(growth)]) { $1 }.merging(Self.gaugeFields(capacity)) { $1 })
        }
        if absoluteWarn {
            logger.warning("内存占用偏高", Self.fields(for: result).merging(Self.gaugeFields(capacity)) { $1 })
        }
        if cpuWarn {
            let top = stats.snapshot(top: 5).map { "\($0.name)=\(Self.format($0.totalMs))ms" }.joined(separator: ",")
            let busy = children.filter { ($0.cpuPercent ?? 0) >= thresholds.cpuWarnPercent }.map { "\($0.role.rawValue):\($0.pid)=\(Self.format($0.cpuPercent ?? 0))%" }.joined(separator: ",")
            logger.warning("CPU 持续偏高", Self.fields(for: result).merging(["topSpans": top, "busyChildren": busy]) { $1 })
        }
        return result
    }

    /// 汇总字段:本进程读数 + 按角色聚合的子进程数量、内存、CPU。
    static func fields(for sample: ResourceSample) -> [String: String] {
        var fields: [String: String] = [
            "footprintMB": format(sample.footprintMB), "peakMB": format(sample.peakMB),
            "threads": "\(sample.threads)", "fds": "\(sample.fds)",
            "children": "\(sample.children.count)", "childMB": format(sample.childrenFootprintMB),
        ]
        if let cpu = sample.cpuPercent { fields["cpuPct"] = format(cpu) }
        for role in ProcessRole.allCases {
            let group = sample.children.filter { $0.role == role }
            guard !group.isEmpty else { continue }
            fields["\(role.rawValue)Count"] = "\(group.count)"
            fields["\(role.rawValue)MB"] = format(group.reduce(0) { $0 + $1.footprintMB })
            let cpus = group.compactMap(\.cpuPercent)
            if !cpus.isEmpty { fields["\(role.rawValue)Cpu"] = format(cpus.reduce(0, +)) }
        }
        return fields
    }

    private static func gaugeFields(_ gauges: [String: Int]) -> [String: String] {
        gauges.mapValues { "\($0)" }
    }

    /// 由累计 CPU 时间差分得到百分比;首次调用只记录基准并返回 nil。
    private static func cpuPercent(mark: inout CPUMark?, nanos: UInt64, now: ContinuousClock.Instant) -> Double? {
        defer { mark = CPUMark(nanos: nanos, at: now) }
        guard let previous = mark else { return nil }
        let wall = now - previous.at
        let wallNanos = Double(wall.components.seconds) * 1e9 + Double(wall.components.attoseconds) / 1e9
        guard wallNanos > 0, nanos >= previous.nanos else { return nil }
        return Double(nanos - previous.nanos) / wallNanos * 100
    }

    private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }
}
