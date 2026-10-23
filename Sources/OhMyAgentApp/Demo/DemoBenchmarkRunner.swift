// @author ixxxxoooo
// 演示基准运行器:在演示模式里对「性能实验室」的项目与会话依次跑项目打开、会话加载、复制、渲染、
// 模型/引擎切换与恢复,并以 0.5 秒间隔采样应用与子进程的真实内存,得到一份 `DemoMetricsReport`。
// 入口:演示指标标签页的按钮,或环境变量 `OMA_DEMO_BENCH=all|open,load,copy,render,switching,memory`(完成后写 JSON 并可退出)。

import ACPKit
import AppKit
import AgentHost
import CanvasKit
import ChatKit
import DemoKit
import EditorKit
import Foundation
import MermaidKit
import Observation
import OMLog
import WorkbenchKit

/// 基准运行器(单例,主线程隔离)。
@MainActor
@Observable
final class DemoBenchmarkRunner {
    static let shared = DemoBenchmarkRunner()

    /// 当前报告(运行中逐项刷新)
    var report = DemoMetricsReport(metrics: DemoBenchmarkCatalog.items.map(\.placeholder))
    /// 是否正在运行
    private(set) var isRunning = false
    /// 正在执行的项目说明
    var currentStep = ""
    /// 运行取消标志
    @ObservationIgnored var cancelled = false
    /// IDE 标签切换的耗时分解(运行循环/布局/绘制,三个一组),供基准说明列出
    @ObservationIgnored var settleBreakdown: [Double] = []
    @ObservationIgnored private var phase = "空闲"
    @ObservationIgnored private var memoryTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt = ContinuousClock.now
    @ObservationIgnored private let log = Log.perf

    private var workbench: WorkbenchModel { AppEnvironment.shared.workbench }

    // MARK: 入口

    /// 运行基准。
    /// - Parameter categories: 要运行的分类
    func run(categories: Set<DemoMetricCategory> = Set(DemoMetricCategory.allCases)) async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        report = DemoMetricsReport(metrics: DemoBenchmarkCatalog.items.map(\.placeholder))
        startedAt = .now
        startMemorySampling()
        defer { stopMemorySampling(); isRunning = false; currentStep = "" }
        let span = log.span("演示基准", warnMs: 600_000, ["categories": categories.map(\.rawValue).sorted().joined(separator: ",")])
        setPhase("基线")
        try? await Task.sleep(for: .seconds(1))
        let baseline = currentFootprint()
        if categories.contains(.open) { await runOpen() }
        if categories.contains(.load) || categories.contains(.copy) || categories.contains(.switching) || categories.contains(.memory) { await runLoadCopySwitch(categories: categories) }
        if categories.contains(.render) { await runRender() }
        if categories.contains(.ide) { await runIDE() }
        if categories.contains(.editor) { await runEditor() }
        if categories.contains(.memory) { await finishMemory(baseline: baseline) }
        report.finishedAt = Date()
        span.end()
        log.info("演示基准完成", ["通过": "\(report.counts.pass)", "偏慢": "\(report.counts.slow)", "失败": "\(report.counts.fail)"])
        writeReportIfRequested()
    }

    /// 取消正在进行的运行(当前步骤结束后停止)。
    func cancel() { cancelled = true }

    /// 结果写盘位置:`OMA_DEMO_BENCH_OUT` 优先,其次演示沙盒根目录下的 `demo-metrics.json`。
    var outputURL: URL? {
        if let path = ProcessInfo.processInfo.environment["OMA_DEMO_BENCH_OUT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return DemoLaunch.environment?.paths.root.appendingPathComponent("demo-metrics.json")
    }

    /// 把报告写成 JSON(同名 `.md` 为汇总)。
    private func writeReportIfRequested() {
        guard let url = outputURL else { return }
        do {
            try report.jsonData().write(to: url, options: .atomic)
            try report.markdown().write(to: url.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
            log.info("演示指标已写入", ["file": url.path])
        } catch {
            log.error("写入演示指标失败", error: error)
        }
    }

    // MARK: 项目打开

    private func runOpen() async {
        setPhase("项目打开")
        for name in ["perf-longchat", "perf-render", "perf-multitab"] {
            guard !cancelled, let project = project(named: name) else { continue }
            currentStep = "打开 \(name)"
            let existed = workbench.sessions[project.id] != nil
            let started = ContinuousClock.now
            workbench.select(project: project.id)
            let ready = await waitUntil(timeout: 15) { self.workbench.sessions[project.id]?.phase == .ready }
            record("open.\(name)", started: started, detail: ready ? (existed ? "会话已存在" : "首次创建会话") : "超时:会话未就绪", failed: !ready)
        }
        guard !cancelled, let multi = project(named: "perf-multitab") else { return }
        currentStep = "索引 1 万文件"
        let started = ContinuousClock.now
        let root = multi.id
        let count = await Task.detached(priority: .userInitiated) { WorkspaceFiles.index(root: root).count }.value
        record("open.index-10k", started: started, detail: "\(count) 个文件", failed: count < DemoLaunch.deepFileFloor)
    }

    // MARK: 会话加载 / 复制 / 切换

    private func runLoadCopySwitch(categories: Set<DemoMetricCategory>) async {
        guard let longChat = project(named: "perf-longchat"), let render = project(named: "perf-render") else { return }
        let loads: [(metric: String, project: ProjectEntry, index: Int)] = [
            ("load.long2000", longChat, 1), ("load.mixed800", longChat, 2), ("load.heavy", longChat, 3), ("load.gallery", render, 1),
        ]
        var longModel: SessionModel?
        var mixedModel: SessionModel?
        var mixedTurns = 0
        var longTurns = 0
        var heavyAfterLong: Double?
        for item in loads where !cancelled {
            setPhase("加载 " + item.metric)
            currentStep = "加载 " + (DemoBenchmarkCatalog.item(id: item.metric)?.title ?? item.metric)
            let sessionId = "demo-\(item.project.name)-\(item.index)"
            let title = DemoHistory.session(id: sessionId)?.title
            let started = ContinuousClock.now
            workbench.openHistory(project: item.project.id, sessionId: sessionId, title: title)
            let loaded = await waitUntil(timeout: 120) {
                guard let model = self.model(for: sessionId, in: item.project.id) else { return false }
                return !model.isReplaying && !model.timeline.entries.isEmpty
            }
            let model = model(for: sessionId, in: item.project.id)
            // 回放结束后时间线可能还在被事件合批追加:条目数连续 3 次(每次 100ms)不变才算稳定,耗时记到「最后一次变化」的时刻
            let replayEnded = ContinuousClock.now
            var settledCount = -1
            var stableRounds = 0
            var lastChange = replayEnded
            while loaded, stableRounds < 3, ContinuousClock.now - started < .seconds(120) {
                let count = model?.timeline.entries.count ?? 0
                if count == settledCount { stableRounds += 1 } else { stableRounds = 0; settledCount = count; lastChange = ContinuousClock.now }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let turns = model?.timeline.entries.filter { $0.kind == .user }.count ?? 0
            let replayMs = Int((replayEnded - started).seconds * 1000)
            var detail = "超时:回放未结束"
            if loaded { detail = "\(model?.timeline.entries.count ?? 0) 条条目 / \(turns) 轮,回放结束于 \(replayMs) ms" }
            record(item.metric, started: started, end: max(lastChange, replayEnded), detail: detail, failed: !loaded)
            try? await Task.sleep(for: .milliseconds(600))   // 让界面挂载与布局落定,内存曲线能看到加载后的稳定值
            if item.metric == "load.long2000" { longModel = model; longTurns = turns; heavyAfterLong = currentFootprint() }
            if item.metric == "load.mixed800" { mixedModel = model; mixedTurns = turns }
        }
        _ = longModel
        if categories.contains(.memory) { heldLongTurns = longTurns; heldMixedTurns = mixedTurns; afterLongMB = heavyAfterLong }
        if categories.contains(.copy), !cancelled { await runCopy(project: longChat) }
        if categories.contains(.switching), !cancelled { await runSwitch(project: longChat, mixed: mixedModel) }
    }

    @ObservationIgnored private var heldLongTurns = 0
    @ObservationIgnored private var heldMixedTurns = 0
    @ObservationIgnored private var afterLongMB: Double?

    private func runCopy(project: ProjectEntry) async {
        setPhase("复制")
        currentStep = "跨叶子全选并复制"
        // 回到 2000 轮长会话的标签,等它挂载
        workbench.openHistory(project: project.id, sessionId: "demo-perf-longchat-1", title: nil)
        try? await Task.sleep(for: .milliseconds(800))
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        guard let window, let leaf = Self.firstTextLeaf(in: window.contentView) else {
            report.record(failedMetric("copy.select-all", reason: "找不到已挂载的文本叶子(窗口不在前台?)"))
            return
        }
        let started = ContinuousClock.now
        SelectionHub.shared.selectAll(from: leaf)
        let text = SelectionHub.shared.selectedText()
        record("copy.select-all", started: started, detail: "\(text.count) 个字符", failed: text.isEmpty)
        SelectionHub.shared.clearSelection()
    }

    private func runSwitch(project: ProjectEntry, mixed: SessionModel?) async {
        setPhase("切换")
        // 切换模型
        currentStep = "切换模型"
        if let model = mixed ?? model(for: "demo-perf-longchat-2", in: project.id),
           let option = model.option(category: "model"),
           let target = option.options.first(where: { .string($0.value) != option.currentValue }) {
            let started = ContinuousClock.now
            model.selectModel(optionId: option.id, value: target.value, useMapping: false)
            let ok = await waitUntil(timeout: 10) { model.option(category: "model")?.currentValue == .string(target.value) }
            record("switch.model", started: started, detail: ok ? "→ \(target.name)" : "超时:模型未生效", failed: !ok)
        } else {
            report.record(failedMetric("switch.model", reason: "当前引擎没有可切换的模型选项"))
        }
        // 切换引擎并恢复:新建引擎会话替换当前标签,再恢复同一个会话
        currentStep = "切换引擎并恢复会话"
        let sessionId = "demo-perf-longchat-2"
        workbench.openHistory(project: project.id, sessionId: sessionId, title: nil)
        try? await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        let replacement = AppEnvironment.makeSession(workspace: project.url, descriptor: Toolchain.defaultDescriptor())
        workbench.replaceSession(for: project.id, with: replacement)
        let ready = await waitUntil(timeout: 20) { replacement.phase == .ready }
        guard ready else { report.record(failedMetric("switch.engine-restore", reason: "新引擎会话未就绪")); return }
        replacement.openSession(SessionSummary(sessionId: sessionId, cwd: project.id, title: DemoHistory.session(id: sessionId)?.title))
        let restored = await waitUntil(timeout: 120) { !replacement.isReplaying && !replacement.timeline.entries.isEmpty }
        record("switch.engine-restore", started: started, detail: restored ? "\(replacement.timeline.entries.count) 条条目" : "超时:恢复未结束", failed: !restored)
    }

    // MARK: 渲染

    private func runRender() async {
        setPhase("渲染")
        currentStep = "Markdown / 表格 / 图表 / Mermaid / 代码"
        let doc = DemoRenderSamples.markdownDocument
        var blocks: [MarkdownBlock] = []
        measure("render.markdown-parse", detail: "\(doc.count) 字符") { blocks = MarkdownParser.parse(doc) }
        measure("render.markdown-runs", detail: "\(blocks.count) 个块") {
            let runs = blocks.filter(isTextRunBlock)
            _ = MarkdownTextRunBuilder.build(runs)
        }
        measure("render.table", detail: "60 行 × 7 列") {
            let parsed = MarkdownParser.parse(DemoRenderSamples.tableMarkdown)
            if case .table(_, let rows, _)? = parsed.first { _ = rows.count }
        }
        measure("render.chart", detail: "折线 + 60 根 K 线") {
            for json in [DemoRenderSamples.lineChartJSON, DemoRenderSamples.candleChartJSON] { _ = try? CanvasParser.parseChart(Data(json.utf8)) }
        }
        var rendered = 0
        measure("render.mermaid", detail: "") { for source in DemoRenderSamples.mermaidSources where (try? Mermaid.scene(for: source)) != nil { rendered += 1 } }
        report.record(updated("render.mermaid") { $0.detail = "\(rendered)/\(DemoRenderSamples.mermaidSources.count) 张成功" })
        let code = DemoRenderSamples.largeSwift
        measure("render.code", detail: "\(code.split(separator: "\n").count) 行") { _ = CodeHighlighter.attributed(code, language: .swift) }
        measure("render.markdown-live", detail: "") { _ = MarkdownLiveRenderer.layout(for: doc) }
    }

    // MARK: 内存

    private func finishMemory(baseline: Double) async {
        setPhase("释放")
        currentStep = "关闭加载的标签并等待释放"
        for tab in workbench.dock.allTabs {
            if case .chat(_, let slot?) = tab.kind, slot.count > 12 { workbench.closeTab(tab.id) }   // 历史会话标签用 UUID 槽位
        }
        try? await Task.sleep(for: .seconds(4))
        let after = currentFootprint()
        let peak = report.memory.map(\.appMB).max() ?? after
        let children = report.memory.last?.childrenMB ?? 0
        let turns = max(heldLongTurns, 1)
        let afterLoad = max((afterLongMB ?? after) - baseline, 0)
        report.record(mbMetric("memory.baseline", baseline, detail: "运行开始前 1 秒"))
        report.record(mbMetric("memory.after-load", afterLoad, detail: "长会话 \(heldLongTurns) 轮 + 混合 \(heldMixedTurns) 轮"))
        report.record(mbMetric("memory.per-1k-turns", afterLoad / Double(turns) * 1_000, detail: "按长会话 \(heldLongTurns) 轮折算"))
        report.record(mbMetric("memory.peak", peak, detail: "含渲染与切换阶段"))
        report.record(mbMetric("memory.after-release", max(after - baseline, 0), detail: "释放后绝对值 \(Int(after)) MB"))
        report.record(mbMetric("memory.children", children, detail: "采样结束时"))
    }

    private func startMemorySampling() {
        report.memory = []
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleMemory()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopMemorySampling() {
        sampleMemory()
        memoryTask?.cancel()
        memoryTask = nil
    }

    private func sampleMemory() {
        guard let sample = ResourceSampler.shared.sample() else { return }
        report.memory.append(DemoMemoryPoint(seconds: Double((ContinuousClock.now - startedAt).seconds), appMB: sample.footprintMB, childrenMB: sample.childrenFootprintMB, phase: phase))
    }

    func currentFootprint() -> Double { report.memory.last?.appMB ?? ResourceSampler.shared.sample()?.footprintMB ?? 0 }

    // MARK: 工具

    func setPhase(_ name: String) { phase = name }

    func project(named name: String) -> ProjectEntry? { workbench.projects.first { $0.name == name } }

    private func model(for sessionId: String, in projectID: String) -> SessionModel? {
        workbench.conversations.first { $0.key.projectID == projectID && $0.value.sessionId == sessionId }?.value
    }

    /// 轮询等待条件成立。
    func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func record(_ id: String, started: ContinuousClock.Instant, end: ContinuousClock.Instant = .now, detail: String, failed: Bool = false) {
        let elapsed = (end - started).seconds * 1000
        report.record(updated(id) { $0.value = failed ? nil : elapsed; $0.detail = detail })
        log.info("演示基准项", ["id": id, "ms": String(format: "%.1f", elapsed), "detail": detail])
    }

    func measure(_ id: String, detail: String, _ body: () -> Void) {
        let started = ContinuousClock.now
        body()
        record(id, started: started, detail: detail)
    }

    func updated(_ id: String, _ change: (inout DemoMetric) -> Void) -> DemoMetric {
        var metric = report.metrics.first { $0.id == id } ?? DemoBenchmarkCatalog.item(id: id)?.placeholder ?? DemoMetric(id: id, category: .render, title: id, purpose: "")
        change(&metric)
        return metric
    }

    private func failedMetric(_ id: String, reason: String) -> DemoMetric { updated(id) { $0.value = nil; $0.detail = reason } }

    private func mbMetric(_ id: String, _ value: Double, detail: String) -> DemoMetric { updated(id) { $0.value = value; $0.detail = detail } }

    /// 在视图树里找「叶子最多的滚动区」里的第一个只读文本叶子(即会话时间线,而不是侧栏等零散文本)。
    private static func firstTextLeaf(in view: NSView?) -> OMReadOnlyTextView? {
        var leaves: [OMReadOnlyTextView] = []
        func collect(_ node: NSView) {
            if let leaf = node as? OMReadOnlyTextView, leaf.window != nil { leaves.append(leaf) }
            for child in node.subviews { collect(child) }
        }
        guard let view else { return nil }
        collect(view)
        let groups = Dictionary(grouping: leaves) { leaf in SelectionHub.scopeScrollView(of: leaf).map { ObjectIdentifier($0) } }
        return groups.values.max { $0.count < $1.count }?.first
    }
}

extension DemoLaunch {
    /// 1 万文件深层目录索引的下限(索引应至少包含这么多文件,否则视为索引失败)。
    static let deepFileFloor = 10_000
}
