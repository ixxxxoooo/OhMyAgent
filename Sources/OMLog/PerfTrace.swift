// @author ixxxxoooo
// 性能追踪:带阈值的耗时跨度(`perf` 分类)与主线程卡顿监视器。
// 跨度结束时记录耗时,超过阈值升级为 warning;卡顿监视器在主线程被阻塞超过阈值时记录时长与最近完成的跨度,
// 便于第一时间定位「哪个操作造成了卡顿」。

import Dispatch
import Foundation
import os
import Synchronization

/// 性能 signpost(Instruments 的 Points of Interest 可直接看到每个跨度)。
private enum PerfSignpost {
    static let signposter = OSSignposter(subsystem: "com.ixxxxoooo.OhMyAgent", category: .pointsOfInterest)
}

/// 最近完成的耗时跨度(环形,仅用于卡顿发生时关联上下文)。
private enum PerfRecent {
    struct Item { let name: String; let ms: Int; let at: ContinuousClock.Instant }
    static let items = Mutex<[Item]>([])

    static func record(name: String, ms: Int) {
        items.withLock { list in
            list.append(Item(name: name, ms: ms, at: .now))
            if list.count > 24 { list.removeFirst(list.count - 24) }
        }
    }

    /// 取最近 `seconds` 秒内完成的跨度摘要(`名称=毫秒`,逗号分隔)。
    static func summary(within seconds: Double) -> String {
        let cutoff = ContinuousClock.now - .milliseconds(Int(seconds * 1000))
        return items.withLock { list in
            list.filter { $0.at >= cutoff }.suffix(6).map { "\($0.name)=\($0.ms)ms" }.joined(separator: ",")
        }
    }
}

/// 一个进行中的耗时跨度。
public struct PerfSpan: Sendable {
    private let name: String
    private let start: ContinuousClock.Instant
    private let warnMs: Int
    private let quiet: Bool
    private let fields: [String: String]
    private let logger: OMLogger
    private let signpost: OSSignpostIntervalState

    fileprivate init(logger: OMLogger, name: String, warnMs: Int, quiet: Bool, fields: [String: String]) {
        self.logger = logger; self.name = name; self.warnMs = warnMs; self.quiet = quiet; self.fields = fields
        let signposter = PerfSignpost.signposter
        self.signpost = signposter.beginInterval("perf", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        self.start = .now
    }

    /// 结束跨度并记录耗时。
    /// - Parameter extra: 结束时才知道的附加字段(如条目数)
    /// - Returns: 耗时毫秒
    @discardableResult
    public func end(_ extra: [String: String] = [:]) -> Int {
        let micros = OMLogger.microseconds(since: start)
        let ms = micros / 1000
        PerfSignpost.signposter.endInterval("perf", signpost)
        PerfStats.shared.record(name: name, micros: micros)
        PerfRecent.record(name: name, ms: ms)
        var all = fields.merging(extra) { $1 }
        all["ms"] = "\(ms)"
        if ms >= warnMs {
            logger.warning("\(name) 耗时较长", all)
        } else if !quiet {
            logger.info("\(name)", all)
        }
        return ms
    }
}

public extension OMLogger {
    /// 开始一个耗时跨度。
    /// - Parameters:
    ///   - name: 操作名
    ///   - warnMs: 超过该毫秒数记为 warning,默认 100
    ///   - quiet: 为 true 时低于阈值不落日志(用于高频路径,只记录慢的)
    ///   - fields: 附加字段
    func span(_ name: String, warnMs: Int = 100, quiet: Bool = false, _ fields: [String: String] = [:]) -> PerfSpan {
        PerfSpan(logger: self, name: name, warnMs: warnMs, quiet: quiet, fields: fields)
    }

    /// 计时执行同步代码并按跨度规则记录(含聚合与 signpost)。
    /// - Parameters:
    ///   - name: 操作名
    ///   - warnMs: 超过该毫秒数记为 warning
    ///   - quiet: 为 true 时低于阈值不落日志
    ///   - fields: 附加字段
    ///   - body: 要执行的代码
    /// - Returns: body 的返回值
    func timed<T>(_ name: String, warnMs: Int = 100, quiet: Bool = false, _ fields: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        let span = span(name, warnMs: warnMs, quiet: quiet, fields)
        defer { span.end() }
        return try body()
    }

    /// 计时执行异步代码并按跨度规则记录(沿用调用方的隔离域)。
    /// - Parameters:
    ///   - name: 操作名
    ///   - warnMs: 超过该毫秒数记为 warning
    ///   - quiet: 为 true 时低于阈值不落日志
    ///   - fields: 附加字段
    ///   - isolation: 调用方隔离域(自动传入)
    ///   - body: 要执行的代码
    /// - Returns: body 的返回值
    func timed<T>(_ name: String, warnMs: Int = 100, quiet: Bool = false, _ fields: [String: String] = [:], isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let span = span(name, warnMs: warnMs, quiet: quiet, fields)
        defer { span.end() }
        return try await body()
    }
}

/// 主线程卡顿监视器:每 50ms 向主线程投递一个探针,探针执行延迟超过阈值即记录。
public final class MainThreadHitchMonitor: @unchecked Sendable {
    public static let shared = MainThreadHitchMonitor()
    private let queue = DispatchQueue(label: "oma.hitch-monitor", qos: .utility)
    private let pending = Mutex(false)
    private let counters = Mutex((count: 0, maxMs: 0))
    /// 最近一次探针的投递时刻(用于判断停滞已持续多久)
    private let postedAt = Mutex<ContinuousClock.Instant?>(nil)
    private var timer: DispatchSourceTimer?
    /// 是否在停滞期间抓取调用栈(正式版也开启,≥1s 才采、≥2s 才落盘;`OMA_HITCH_SAMPLE=0` 关闭)
    private let sampleStacks = HitchStackSampler.isSamplingAllowed()
    private let sampler = HitchStackSampler.shared

    /// 自启动以来的卡顿累计:次数与单次最大毫秒。
    public var totals: (count: Int, maxMs: Int) { counters.withLock { $0 } }

    /// 启动监视(幂等)。
    /// - Parameter thresholdMs: 主线程延迟超过该毫秒数记为卡顿,默认 100
    public func start(thresholdMs: Int = 100) {
        queue.async { [self] in
            guard timer == nil else { return }
            if sampleStacks { DispatchQueue.main.async { HitchStackSampler.shared.attachMainThread() } }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(50))
            source.setEventHandler { [self] in
                let alreadyPending = pending.withLock { value -> Bool in
                    if value { return true }
                    value = true
                    return false
                }
                guard !alreadyPending else {
                    // 探针迟迟没被主线程执行:停滞仍在进行中,必要时抓栈(此刻主线程恰好卡在问题现场)
                    if sampleStacks, let since = postedAt.withLock({ $0 }) {
                        sampler.stallDetected(stalledMs: OMLogger.milliseconds(since: since), postedAt: since)
                    }
                    return
                }
                let posted = ContinuousClock.now
                postedAt.withLock { $0 = posted }
                DispatchQueue.main.async { [self] in
                    pending.withLock { $0 = false }
                    let ms = OMLogger.milliseconds(since: posted)
                    if sampleStacks { sampler.stallEnded(totalMs: ms) }
                    guard ms >= thresholdMs else { return }
                    let total = counters.withLock { value -> Int in
                        value.count += 1
                        value.maxMs = max(value.maxMs, ms)
                        return value.count
                    }
                    PerfStats.shared.record(name: "主线程卡顿", micros: ms * 1000)
                    Log.perf.warning("主线程卡顿", ["ms": "\(ms)", "total": "\(total)", "recent": PerfRecent.summary(within: 2)])
                }
            }
            source.resume()
            timer = source
        }
    }
}
