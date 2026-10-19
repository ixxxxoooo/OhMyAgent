// @author ixxxxoooo
// 侧栏开关性能探针:记录「点击 → 首帧」耗时、动画期间的帧间隔(卡顿帧)与各关键视图 body 的重算次数,
// 结果以一条 perf 日志输出(`Scripts/logs.sh` 中搜索「侧栏切换」),用于定位开关卡顿的来源。

import AppKit
import OMLog
import QuartzCore
import WorkbenchKit

/// 侧栏开关性能探针(仅主线程使用)。
@MainActor
enum PanelToggleProbe {
    /// 最近的 body 重算记录(名称 + 时刻),上限 2000 条;汇总时只统计切换之后的。
    private static var bodyEvents: [(name: String, at: ContinuousClock.Instant)] = []
    private static var sampler: FrameSampler?

    /// 登记一次 body 重算;放在视图 body 开头:`let _ = PanelToggleProbe.count("名称")`。
    /// - Parameter name: 视图名
    /// - Returns: 恒为 0(便于写成 `let _ =`)
    @discardableResult
    static func count(_ name: String) -> Int {
        bodyEvents.append((name, .now))
        if bodyEvents.count > 2000 { bodyEvents.removeFirst(1000) }
        return 0
    }

    /// 某时刻之后各视图 body 的重算次数(基准钩子汇总用)。
    /// - Parameter since: 起始时刻
    /// - Returns: 视图名 → 次数
    static func bodyCounts(since: ContinuousClock.Instant) -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in bodyEvents where event.at >= since { counts[event.name, default: 0] += 1 }
        return counts
    }

    /// 面板显隐变化时调用,开始采样约 0.6 秒。
    /// - Parameters:
    ///   - stamp: 模型在切换瞬间记录的时间戳
    ///   - window: 主窗口(用于创建显示链接)
    static func begin(stamp: PanelToggleStamp?, window: NSWindow?) {
        guard let view = window?.contentView else { return }
        sampler?.finish()
        let sampler = FrameSampler(name: stamp?.name ?? "未知", start: stamp?.at ?? .now, view: view) { result in
            Self.report(result, since: stamp?.at ?? .now)
            Self.sampler = nil
        }
        Self.sampler = sampler
    }

    /// 输出汇总日志;存在超过 33ms 的帧时记为 warning。
    private static func report(_ r: FrameSampler.Result, since: ContinuousClock.Instant) {
        var bodyCounts: [String: Int] = [:]
        for event in bodyEvents where event.at >= since { bodyCounts[event.name, default: 0] += 1 }
        let counts = bodyCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let fields: [String: String] = [
            "panel": r.name, "firstFrameMs": String(format: "%.1f", r.firstFrameMs),
            "frames": "\(r.frames)", "avgMs": String(format: "%.1f", r.avgMs),
            "maxMs": String(format: "%.1f", r.maxMs), "hitches": "\(r.hitches)", "bodies": counts,
        ]
        if r.hitches > 0 || r.firstFrameMs > 50 { Log.perf.warning("侧栏切换", fields) } else { Log.perf.info("侧栏切换", fields) }
    }
}

/// 基于 `CADisplayLink` 的帧间隔采样器。
@MainActor
final class FrameSampler: NSObject {
    /// 采样结果。
    struct Result {
        var name: String
        var firstFrameMs: Double
        var frames: Int
        var avgMs: Double
        var maxMs: Double
        var hitches: Int
    }

    private let name: String
    private let start: ContinuousClock.Instant
    private let onDone: (Result) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var firstFrameMs: Double = 0
    private var began: CFTimeInterval = 0

    init(name: String, start: ContinuousClock.Instant, view: NSView, onDone: @escaping (Result) -> Void) {
        self.name = name
        self.start = start
        self.onDone = onDone
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// 每帧回调:首帧记录点击到首帧耗时,之后记录帧间隔,满 0.6 秒结束。
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last == 0 {
            let d = ContinuousClock.now - start
            firstFrameMs = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            began = now
        } else {
            intervals.append((now - last) * 1000)
        }
        last = now
        if now - began > 0.6 { finish() }
    }

    /// 结束采样并回调结果(可重复调用)。
    func finish() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let total = intervals.reduce(0, +)
        onDone(Result(name: name, firstFrameMs: firstFrameMs, frames: intervals.count + 1,
                      avgMs: intervals.isEmpty ? 0 : total / Double(intervals.count),
                      maxMs: intervals.max() ?? 0, hitches: intervals.filter { $0 > 33 }.count))
    }
}
