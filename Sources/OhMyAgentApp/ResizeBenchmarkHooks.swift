// @author ixxxxoooo
// 窗口缩放 / 拖分栏 / 滚动 流畅度基准钩子(仅脚本化验证用,不影响正常使用):
// - `OMA_RESIZE_SWEEP=N`:把主窗口宽度在 1400↔900 之间逐帧 `setFrame`,往返 N 次;
// - `OMA_DRAG_SWEEP=sidebar|tools|bottom|dock`:按与 `PanelResizer` 相同的写入路径逐帧改尺寸(dock 直接逐帧提交比例,代表最坏情况);
// - `OMA_SCROLL_SWEEP=N`:对会话流的 `NSScrollView` 逐帧上下滚动 N 个来回(演示场景请选长会话)。
// 每项结束输出一条 perf 日志「缩放基准 / 拖分栏基准 / 滚动基准」:平均帧间隔、>33ms 掉帧数、单帧最长、各视图 body 次数。
// 汇总见 `Scripts/perf-ui.sh resize|drag|scroll`。

import AppKit
import OMLog
import QuartzCore
import WorkbenchKit

/// 基准扫描的纯计算部分(与 AppKit 解耦,便于测试)。
enum SweepPlan {
    /// 在 `low…high` 之间生成往返 `cycles` 次的宽度序列(每个来回 `steps` 步下行 + `steps` 步上行),起止都在 `high`。
    /// - Parameters:
    ///   - low: 下限
    ///   - high: 上限
    ///   - steps: 单程步数(≥1)
    ///   - cycles: 往返次数(≤0 返回空)
    /// - Returns: 逐帧数值序列
    static func zigzag(low: Double, high: Double, steps: Int, cycles: Int) -> [Double] {
        guard cycles > 0, steps > 0, high >= low else { return [] }
        let delta = (high - low) / Double(steps)
        var values: [Double] = []
        values.reserveCapacity(cycles * steps * 2)
        for _ in 0..<cycles {
            for step in 1...steps { values.append(high - delta * Double(step)) }
            for step in 1...steps { values.append(low + delta * Double(step)) }
        }
        return values
    }

    /// 汇总一组帧间隔(毫秒)。
    /// - Parameter intervals: 帧间隔序列
    /// - Returns: 帧数、平均、最长与超过 33ms 的掉帧数
    static func summarize(_ intervals: [Double]) -> (frames: Int, avgMs: Double, maxMs: Double, hitches: Int) {
        guard !intervals.isEmpty else { return (0, 0, 0, 0) }
        return (intervals.count + 1, intervals.reduce(0, +) / Double(intervals.count), intervals.max() ?? 0, intervals.filter { $0 > 33 }.count)
    }
}

/// 连续帧间隔采样器:`start` 后每个显示帧记录一次间隔,`stop` 时汇总。
@MainActor
private final class SweepSampler: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []

    /// 开始采样。
    /// - Parameter view: 用于创建显示链接的视图
    init(view: NSView) {
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last != 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }

    /// 结束采样并汇总。
    func stop() -> (frames: Int, avgMs: Double, maxMs: Double, hitches: Int) {
        link?.invalidate()
        link = nil
        return SweepPlan.summarize(intervals)
    }
}

@MainActor
enum ResizeBenchmarkHooks {
    /// 按环境变量依次执行已启用的扫描基准。
    /// - Parameters:
    ///   - env: 环境变量
    ///   - workbench: 工作台模型
    static func runIfRequested(env: [String: String], workbench: WorkbenchModel) async {
        guard env["OMA_RESIZE_SWEEP"] != nil || env["OMA_DRAG_SWEEP"] != nil || env["OMA_SCROLL_SWEEP"] != nil else { return }
        // 等场景跑完(会话不再运行)再开始测量,并留出渲染稳定时间
        for _ in 0..<300 where workbench.activeSession?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1.5))
        if let cycles = env["OMA_RESIZE_SWEEP"].flatMap(Int.init), cycles > 0 { await resizeSweep(cycles: cycles) }
        if let kind = env["OMA_DRAG_SWEEP"], !kind.isEmpty { await dragSweep(kind: kind, workbench: workbench) }
        if let cycles = env["OMA_SCROLL_SWEEP"].flatMap(Int.init), cycles > 0 { await scrollSweep(cycles: cycles) }
    }

    /// 主窗口。
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.resizable) && $0.level == .normal }
    }

    /// 等待下一个显示帧(~16ms)。
    private static func nextFrame() async { try? await Task.sleep(for: .milliseconds(16)) }

    /// 输出汇总日志。
    private static func report(_ name: String, _ r: (frames: Int, avgMs: Double, maxMs: Double, hitches: Int), since: ContinuousClock.Instant, extra: [String: String] = [:]) {
        let counts = PanelToggleProbe.bodyCounts(since: since).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        var fields: [String: String] = [
            "frames": "\(r.frames)", "avgMs": String(format: "%.1f", r.avgMs),
            "maxMs": String(format: "%.1f", r.maxMs), "hitches": "\(r.hitches)", "bodies": counts,
        ]
        fields.merge(extra) { _, new in new }
        Log.perf.info(name, fields)
    }

    /// 窗口宽度往返扫描。
    private static func resizeSweep(cycles: Int) async {
        guard let window = mainWindow, let view = window.contentView else {
            Log.perf.warning("缩放基准:没有可用的主窗口")
            return
        }
        Log.perf.info("基准阶段", ["phase": "窗口缩放开始"])
        let origin = window.frame
        let widths = SweepPlan.zigzag(low: 900, high: 1400, steps: 20, cycles: cycles)
        window.setFrame(NSRect(x: origin.minX, y: origin.minY, width: 1400, height: origin.height), display: true)
        try? await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        let sampler = SweepSampler(view: view)
        for width in widths {
            var frame = window.frame
            frame.size.width = width
            window.setFrame(frame, display: true)
            await nextFrame()
        }
        report("缩放基准", sampler.stop(), since: start, extra: ["cycles": "\(cycles)"])
        window.setFrame(origin, display: true)
        Log.perf.info("基准阶段", ["phase": "窗口缩放结束"])
    }

    /// 拖分栏扫描(`sidebar`/`tools`/`bottom` 与 `PanelResizer` 同一写入路径:拖动中只写临时值,结束提交;`dock` 逐帧提交比例)。
    private static func dragSweep(kind: String, workbench: WorkbenchModel) async {
        guard let view = mainWindow?.contentView else {
            Log.perf.warning("拖分栏基准:没有可用的主窗口")
            return
        }
        Log.perf.info("基准阶段", ["phase": "拖分栏开始", "kind": kind])
        let start = ContinuousClock.now
        let sampler = SweepSampler(view: view)
        switch kind {
        case "sidebar", "tools", "bottom":
            let dimension: PanelDimension = kind == "sidebar" ? .leftWidth : (kind == "tools" ? .rightWidth : .bottomHeight)
            if kind == "bottom" { workbench.layout.bottomVisible = true }
            if kind == "tools" { workbench.layout.rightVisible = true }
            let base = dimension.committed(in: workbench.layout)
            let values = SweepPlan.zigzag(low: dimension.clamp(base - 120), high: dimension.clamp(base + 120), steps: 30, cycles: 3)
            for value in values {
                workbench.panelDrag.update(value, for: dimension)
                await nextFrame()
            }
            workbench.commitPanelDrag(dimension)
        case "dock":
            if case .split(let split) = workbench.dock.root, split.children.count == 2 {
                for value in SweepPlan.zigzag(low: 0.3, high: 0.7, steps: 30, cycles: 3) {
                    workbench.dock.setRatios([value, 1 - value], forSplit: split.id)
                    await nextFrame()
                }
            } else {
                Log.perf.warning("拖分栏基准:编辑区没有两栏分屏(可用 OMA_OPEN_FILE + OMA_SPLIT=right 构造)")
            }
        default:
            Log.perf.warning("拖分栏基准:未知类型", ["kind": kind])
        }
        report("拖分栏基准", sampler.stop(), since: start, extra: ["kind": kind])
        Log.perf.info("基准阶段", ["phase": "拖分栏结束"])
    }

    /// 会话流滚动扫描:找到内容最高的 `NSScrollView` 逐帧上下滚动。
    private static func scrollSweep(cycles: Int) async {
        guard let root = mainWindow?.contentView, let scroll = tallestScrollView(in: root) else {
            Log.perf.warning("滚动基准:没有找到可滚动的会话流")
            return
        }
        guard let document = scroll.documentView else { return }
        let travel = max(document.frame.height - scroll.contentView.bounds.height, 0)
        guard travel > 0 else {
            Log.perf.warning("滚动基准:内容不足以滚动", ["contentHeight": String(format: "%.0f", document.frame.height)])
            return
        }
        Log.perf.info("基准阶段", ["phase": "滚动开始"])
        let start = ContinuousClock.now
        let sampler = SweepSampler(view: root)
        for offset in SweepPlan.zigzag(low: 0, high: travel, steps: 60, cycles: cycles) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            await nextFrame()
        }
        report("滚动基准", sampler.stop(), since: start, extra: ["cycles": "\(cycles)", "travel": String(format: "%.0f", travel)])
        Log.perf.info("基准阶段", ["phase": "滚动结束"])
    }

    /// 视图树里文档高度最大的滚动视图(即会话流)。
    private static func tallestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ node: NSView) {
            if let scroll = node as? NSScrollView, let doc = scroll.documentView, !scroll.isHiddenOrHasHiddenAncestor {
                if doc.frame.height > (best?.documentView?.frame.height ?? 0) { best = scroll }
            }
            node.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
