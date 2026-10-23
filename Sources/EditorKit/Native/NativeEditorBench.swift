// @author ixxxxoooo
// 原生编辑器(native2)基准内核:在屏幕上几乎透明的小窗口里,用合成的 Swift 文本实测打开、滚动、输入、
// 增量语法、补全浮层与 Agent 流式补丁的关键指标。结果由 `DemoBenchmarkRunner+Editor` 挂到 `editor.*` 度量点,
// 预算(120Hz)见 `DemoBenchmarkCatalog`:滚动 p50 ≤ 8.4ms / p99 ≤ 11ms / 掉帧 < 1%,输入 p95 ≤ 4ms / max ≤ 8ms,
// 5 万行打开首帧 ≤ 40ms / 可交互 ≤ 100ms,100 万行 ≤ 800ms 且内存 ≤ 文件的 2.5 倍,增量语法 ≤ 2ms,补全浮层 ≤ 16ms,
// Agent 200 补丁/秒(单个补丁 ≤ 5ms)。

import AppKit
import DiffKit
import EditorCore
import OMLog
import Darwin
import QuartzCore

/// 一项基准结果。
public struct NativeBenchResult: Sendable, Equatable {
    /// 度量点标识(`editor.*`)。
    public let id: String
    /// 数值(毫秒、MB 或百分比)。
    public let value: Double
    /// 补充说明。
    public let detail: String

    public init(id: String, value: Double, detail: String) {
        self.id = id
        self.value = value
        self.detail = detail
    }
}

/// 基准内核。
@MainActor
public enum NativeEditorBench {
    // MARK: 合成素材

    /// 生成合成的 Swift 源码(平均每行约 32 字节,含缩进、注释与字符串,便于语法着色有真实工作量)。
    /// - Parameter lines: 目标行数(≤0 返回空串)
    /// - Returns: 源码文本
    public static func synthSwift(lines: Int) -> String {
        guard lines > 0 else { return "" }
        var parts: [String] = []
        parts.reserveCapacity(lines)
        var index = 0
        var block = 0
        while parts.count < lines {
            let name = "Block\(block)"
            parts.append("/// \(name) 的说明文字,用于模拟文档注释。")
            parts.append("struct \(name): Sendable {")
            parts.append("    var id: Int = \(block)")
            parts.append("    var title: String = \"item-\(block)\"")
            parts.append("    func compute(_ value: Int) -> Int {")
            parts.append("        let scaled = value * \(block % 7 + 1)")
            parts.append("        if scaled > \(block % 100) { return scaled - 1 }")
            parts.append("        return scaled + id")
            parts.append("    }")
            parts.append("}")
            parts.append("")
            block += 1
            index += 11
        }
        return parts.prefix(lines).joined(separator: "\n") + "\n"
    }

    /// 取已排序样本的分位数(`p` 取 0…1)。
    /// - Parameters:
    ///   - sorted: 升序样本
    ///   - p: 分位
    /// - Returns: 分位值;样本为空返回 0
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
    }

    // MARK: 宿主

    /// 基准宿主:几乎透明、不抢焦点、可被合成(显示链接才会触发)的窗口 + 编辑器视图。
    @MainActor private final class Host {
        let window: NSWindow
        let view: OMEditorView

        init(text: String, language: SyntaxLanguage = .swift, size: NSSize = NSSize(width: 1_000, height: 700)) {
            let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
            view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
            window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0.02
            window.ignoresMouseEvents = true
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            // 必须上屏:不可见窗口既不会真正绘制,显示链接也不会触发
            window.orderFrontRegardless()
        }

        /// 缓存位图(层背景视图的 `displayIfNeeded` 不会同步绘制,改用 `cacheDisplay` 强制完整执行一次 `draw(_:)`)。
        private var bitmap: NSBitmapImageRep?

        /// 布局并同步绘制一帧(CPU 光栅化到位图,与 CALayer 的 `draw` 走同一条 CoreGraphics 路径)。
        func paint() {
            window.contentView?.layoutSubtreeIfNeeded()
            if bitmap == nil || bitmap?.size != view.bounds.size { bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) }
            if let bitmap { view.cacheDisplay(in: view.bounds, to: bitmap) }
        }

        func close() { window.close() }
    }

    private static func ms(_ from: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - from
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func footprintMB() -> Double { ResourceSampler.shared.sample()?.footprintMB ?? 0 }

    private static func settledFootprintMB() async -> Double {
        try? await Task.sleep(for: .milliseconds(600))
        _ = malloc_zone_pressure_relief(nil, 0)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(300))
            best = min(best, footprintMB())
        }
        return best
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // MARK: 入口

    /// 运行全部基准。
    /// - Parameters:
    ///   - quick: 快速模式(缩小规模,仅用于测试冒烟;度量值不可与预算比较)
    ///   - progress: 阶段回调
    /// - Returns: 结果列表
    public static func run(quick: Bool = false, progress: ((String) -> Void)? = nil) async -> [NativeBenchResult] {
        var results: [NativeBenchResult] = []
        let big = synthSwift(lines: quick ? 2_000 : 50_000)
        progress?("编辑器:打开 5 万行")
        results += await benchOpen(text: big)
        progress?("编辑器:滚动")
        results += await benchScroll(text: big, sweepSeconds: quick ? 0.6 : 4)
        progress?("编辑器:输入")
        results += await benchTyping(text: big, count: quick ? 30 : 200)
        progress?("编辑器:增量语法")
        results += await benchSyntax(text: big, count: quick ? 5 : 20)
        progress?("编辑器:补全浮层")
        results += await benchCompletion(count: quick ? 5 : 30)
        progress?("编辑器:Agent 流式补丁")
        results += await benchAgentPatches(patches: quick ? 20 : 200)
        progress?("编辑器:打开 100 万行")
        results += await benchOpenHuge(lines: quick ? 20_000 : 1_000_000)
        return results
    }

    // MARK: 打开

    private static func benchOpen(text: String) async -> [NativeBenchResult] {
        var first: [Double] = []
        var interactive: [Double] = []
        var highlight: [Double] = []
        // 取三次中位数,抹平首次的一次性初始化(字体、图层)
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let host = Host(text: text)
            host.paint()
            first.append(ms(started))
            // 可交互 = 首帧后第一次按键已经上屏(语法着色在后台进行,不阻塞输入;着色耗时另记在说明里)
            host.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            host.paint()
            interactive.append(ms(started))
            let ready = await waitUntil(timeout: 10) { host.view.tokens.syncCount >= 1 }
            highlight.append(ready ? ms(started) : 10_000)
            host.close()
        }
        let lines = text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        return [
            NativeBenchResult(id: "editor.open-50k", value: first.sorted()[1], detail: "\(lines) 行,装入文档 + 布局 + 首帧绘制,3 次中位数"),
            NativeBenchResult(id: "editor.open-50k-interactive", value: interactive.sorted()[1], detail: "首帧 + 首次按键上屏,3 次中位数;首批语法着色在 \(Int(highlight.sorted()[1])) ms 后到达(后台)"),
        ]
    }

    /// 装入大文件:合成文本只在本函数内存活,返回时仅剩视图持有的 rope,便于量「打开后的常驻内存」。
    private static func openHuge(lines: Int) -> (host: Host, fileMB: Double, openMs: Double) {
        let text = synthSwift(lines: lines)
        let fileMB = Double(text.utf8.count) / 1_048_576
        let started = ContinuousClock.now
        let host = Host(text: text)
        host.paint()
        return (host, fileMB, ms(started))
    }

    private static func benchOpenHuge(lines: Int) async -> [NativeBenchResult] {
        let base = await settledFootprintMB()
        let opened = openHuge(lines: lines)
        _ = await waitUntil(timeout: 5) { opened.host.view.tokens.syncCount >= 1 }
        let held = await settledFootprintMB()
        opened.host.close()
        let delta = max(held - base, 0)
        let ratio = opened.fileMB > 0 ? delta / opened.fileMB : 0
        return [
            NativeBenchResult(id: "editor.open-1m", value: opened.openMs, detail: "\(lines) 行 / \(String(format: "%.1f", opened.fileMB)) MB,装入 rope + 首帧(不含合成文本)"),
            NativeBenchResult(id: "editor.memory-1m", value: delta, detail: "文件 \(String(format: "%.1f", opened.fileMB)) MB,打开后内存增量 \(String(format: "%.1f", delta)) MB(\(String(format: "%.2f", ratio)) 倍)"),
        ]
    }

    // MARK: 滚动

    private static func benchScroll(text: String, sweepSeconds: Double) async -> [NativeBenchResult] {
        let host = Host(text: text)
        host.paint()
        _ = await waitUntil(timeout: 10) { host.view.tokens.syncCount >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        let view = host.view
        let row = Double(view.model.lineHeight)
        // 1. 同步绘制耗时:每步下移 3 行并同步绘制,记录单帧成本
        var costs: [Double] = []
        for step in 0..<400 {
            let t0 = ContinuousClock.now
            view.scroll(y: CGFloat(Double(step) * row * 3))
            host.paint()
            costs.append(ms(t0))
        }
        costs.sort()
        let p50 = percentile(costs, 0.5), p99 = percentile(costs, 0.99)
        // 2. 显示链接:匀速滚动若干秒,统计相邻帧间隔超过名义帧时长 1.5 倍的比例
        view.scroll(y: 0)
        host.paint()
        let sampler = FrameSampler(view: view)
        let nominal = 1000.0 / Double(max(host.window.screen?.maximumFramesPerSecond ?? 60, 30))
        let started = ContinuousClock.now
        var travelled = 0.0
        while ms(started) < sweepSeconds * 1000 {
            travelled += row * 2
            view.scroll(y: CGFloat(travelled))
            try? await Task.sleep(for: .milliseconds(Int(nominal)))
        }
        let intervals = sampler.stop()
        host.close()
        let dropped = intervals.filter { $0 > nominal * 1.5 }.count
        let measured = intervals.count >= 20
        let ratio = measured ? Double(dropped) / Double(intervals.count) * 100 : 0
        let detail = measured ? "\(intervals.count) 帧,名义 \(String(format: "%.1f", nominal)) ms,掉帧 \(dropped)" : "显示链接帧数不足(\(intervals.count)),按 0 计"
        return [
            NativeBenchResult(id: "editor.scroll-p50", value: p50, detail: "400 步同步滚动+绘制单帧中位数"),
            NativeBenchResult(id: "editor.scroll-p99", value: p99, detail: "400 步单帧 P99,最大 \(String(format: "%.1f", costs.last ?? 0)) ms"),
            NativeBenchResult(id: "editor.scroll-dropped", value: ratio, detail: detail),
        ]
    }

    /// 显示链接帧间隔采样器。
    @MainActor private final class FrameSampler: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var intervals: [Double] = []

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

        func stop() -> [Double] {
            link?.invalidate()
            link = nil
            return intervals
        }
    }

    // MARK: 输入

    private static func benchTyping(text: String, count: Int) async -> [NativeBenchResult] {
        let host = Host(text: text)
        host.paint()
        _ = await waitUntil(timeout: 10) { host.view.tokens.syncCount >= 1 }
        let view = host.view
        view.model.setSelections(SelectionSet([Selection(caret: view.model.document.length / 2)]))
        view.scrollToLine(view.model.document.snapshot.line(containing: view.model.document.length / 2), centered: true)
        host.paint()
        var samples: [Double] = []
        for _ in 0..<count {
            let t0 = ContinuousClock.now
            view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            host.paint()
            samples.append(ms(t0))
            try? await Task.sleep(for: .milliseconds(8))
        }
        host.close()
        samples.sort()
        return [
            NativeBenchResult(id: "editor.typing-p95", value: percentile(samples, 0.95), detail: "5 万行文件中部连续输入 \(count) 次(插入 + 布局 + 绘制)"),
            NativeBenchResult(id: "editor.typing-max", value: samples.last ?? 0, detail: "同上最大值"),
        ]
    }

    // MARK: 语法

    private static func benchSyntax(text: String, count: Int) async -> [NativeBenchResult] {
        let engine = HighlightEngine()
        _ = await engine.rebuild(text: text, language: .swift)
        var length = text.utf16.count
        let midpoint = length / 2
        var parse: [Double] = []
        var incremental = true
        for index in 0..<count {
            let edit = TextUnitEdit(location: midpoint + index, oldLength: 0, replacement: [0x78])
            let synced = await engine.applyEdits([edit], oldLength: length, newLength: length + 1, language: .swift)
            incremental = incremental && synced
            length += 1
            parse.append(await engine.lastParseMs)
        }
        parse.sort()
        return [NativeBenchResult(id: "editor.syntax-incremental", value: percentile(parse, 0.5),
                                  detail: "\(count) 次中位数(纯重解析耗时,\(incremental ? "增量" : "含非增量回退"))")]
    }

    // MARK: 补全

    private static func benchCompletion(count: Int) async -> [NativeBenchResult] {
        let host = Host(text: synthSwift(lines: 400))
        host.paint()
        let items = (0..<500).map { NativeCompletionItem(label: "member\($0)", detail: "Int", kind: .property) }
        host.view.languageController.services.completion = { _ in items }
        host.window.makeFirstResponder(host.view)
        // 光标在行首:查询串为空,500 个候选全部通过过滤(最坏的列表规模)
        host.view.model.setSelections(SelectionSet([Selection(caret: 0)]))
        var samples: [Double] = []
        for _ in 0..<count {
            let t0 = ContinuousClock.now
            host.view.languageController.triggerCompletion(auto: false)
            let shown = await waitUntil(timeout: 2) { host.view.languageController.isPopupShown }
            host.paint()
            if shown { samples.append(ms(t0)) }
            host.view.languageController.dismissPopup()
        }
        host.close()
        guard !samples.isEmpty else { return [NativeBenchResult(id: "editor.completion-popup", value: 2_000, detail: "浮层没有出现")] }
        samples.sort()
        return [NativeBenchResult(id: "editor.completion-popup", value: percentile(samples, 0.95), detail: "500 个候选,触发到浮层绘制完成 P95(\(samples.count) 次)")]
    }

    // MARK: Agent 流式补丁

    private static func benchAgentPatches(patches: Int) async -> [NativeBenchResult] {
        let old = synthSwift(lines: 2_000)
        let host = Host(text: old)
        host.paint()
        var lines = old.components(separatedBy: "\n")
        var samples: [Double] = []
        let started = ContinuousClock.now
        for index in 0..<patches {
            // 每个补丁:改一行并追加一行(模拟 Agent 逐段写入),随后重算 Diff、刷新行内审阅、整体绘制
            lines[(index * 7) % lines.count] = "    let patched\(index) = \(index)"
            lines.insert("    // patch \(index)", at: min(10 + index, lines.count))
            let new = lines.joined(separator: "\n")
            let t0 = ContinuousClock.now
            let diff = LineDiff.diff(old: old, new: new)
            _ = try? host.view.model.document.apply([DocumentEdit(range: TextSpan(location: 0, length: host.view.model.document.length), text: new)],
                                                    selectionsBefore: host.view.model.selections.selections,
                                                    selectionsAfter: [Selection(caret: 0)], coalesceKey: nil)
            host.view.inlineReview.show(diff: diff, title: { _ in "Agent" }, actions: [])
            host.paint()
            samples.append(ms(t0))
        }
        let total = ms(started)
        host.close()
        samples.sort()
        let rate = total > 0 ? Double(patches) / (total / 1000) : 0
        return [NativeBenchResult(id: "editor.agent-patch", value: percentile(samples, 0.95),
                                  detail: "\(patches) 个补丁(2000 行文件重算 Diff + 行内审阅 + 绘制)P95,吞吐 \(Int(rate)) 个/秒,最大 \(String(format: "%.1f", samples.last ?? 0)) ms")]
    }
}
