// @author ixxxxoooo
// IDE 模式基准(I13):在演示空间里实测编辑器与窗口的关键指标,结果挂到 `ide.*` 度量点(带预算)。
// 编辑器场景放在屏幕外的无边框窗口里(不抢焦点、不可见),用同步的「布局 + 绘制」耗时近似按键到上屏与滚动帧。
// 需要真实交互才能量的项(minimap 局部重画、资源管理器展开/滚动、主题切换)不在此处,保持「仅展示」。

import AppKit
import DemoKit
import EditorKit
import Darwin
import Foundation
import IDEKit
import OMLog
import WorkbenchKit

extension DemoBenchmarkRunner {
    /// 运行全部 IDE 基准。
    func runIDE() async {
        setPhase("IDE 模式")
        guard let multi = project(named: "perf-multitab") else {
            Log.perf.warning("IDE 基准:缺少 perf-multitab 项目,跳过")
            return
        }
        let root = multi.id
        let lab = root + "/ide-lab"
        let big = lab + "/big/Big50k.swift"
        let medium = lab + "/big/Medium2k.swift"
        guard let bigText = try? String(contentsOfFile: big, encoding: .utf8), let mediumText = try? String(contentsOfFile: medium, encoding: .utf8) else {
            Log.perf.warning("IDE 基准:缺少 ide-lab 素材", ["root": lab])
            return
        }
        let baseline = footprintMB()

        // 1. 窗口冷开/热切换与 20 轮漂移
        currentStep = "IDE 窗口开关 20 轮"
        let sweep = await IDEDebugHooks.sweep(rounds: 20, root: root)
        setValue("ide.window-cold", sweep.coldMedianMs, "20 轮中位数")
        setValue("ide.switch-warm", sweep.warmMedianMs, "20 轮中位数")
        setValue("ide.memory-drift", max(sweep.driftMB, 0), "20 轮开关后的漂移")

        // 2. 编辑器:打开 / 输入 / 滚动
        if !cancelled { await benchEditor(mediumText: mediumText, bigText: bigText) }
        // 3. 语法解析
        if !cancelled { await benchSyntax(bigText: bigText) }
        // 4. 快速打开与全文搜索
        if !cancelled { await benchPaletteAndSearch(root: root) }
        // 5. 窗口内:标签切换与内存
        if !cancelled { await benchWindows(root: root, lab: lab, bigPath: big, baseline: baseline) }
        // 其余项:需真实交互
        for id in ["ide.minimap-redraw", "ide.explorer-expand", "ide.explorer-scroll", "ide.theme-switch"] {
            report.record(updated(id) { $0.detail = "需要真实交互测量,不在自动基准内" })
        }
    }

    // MARK: 编辑器

    /// 屏幕外的编辑器窗口(不可见、不抢焦点)。
    private func makeBenchEditor(wrap: Bool) -> (CodeEditorView, NSWindow) {
        let editor = CodeEditorView(isEditable: true)
        editor.chrome = [.minimap, .stickyScroll, .folding]
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1_000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFrontRegardless()
        editor.wrapsLines = wrap
        return (editor, window)
    }

    private func benchEditor(mediumText: String, bigText: String) async {
        currentStep = "编辑器:打开与输入"
        // 打开普通文件:到首个高亮帧
        do {
            let (editor, window) = makeBenchEditor(wrap: true)
            let started = ContinuousClock.now
            editor.setText(mediumText, language: .swift)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let highlighted = await waitUntil(timeout: 5) { editor.highlightedRange.length > 0 }
            record("ide.open-file", started: started, detail: highlighted ? "Medium2k.swift(2000 行)" : "超时:没有出现高亮", failed: !highlighted)
            window.close()
        }
        // 50k 行文件(不换行):装载到首次绘制
        var typing: [Double] = []
        var scrollAverage = 0.0
        for wrap in [false, true] {
            let (editor, window) = makeBenchEditor(wrap: wrap)
            let started = ContinuousClock.now
            editor.setText(bigText, language: .swift)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if !wrap { record("ide.open-50k", started: started, detail: "Big50k.swift,不换行") }
            _ = await waitUntil(timeout: 10) { editor.highlightedRange.length > 0 }
            try? await Task.sleep(for: .milliseconds(500))
            // 输入:在文件中部连续键入,每次量「插入 + 布局 + 绘制」
            editor.goToLine(25_000)
            window.displayIfNeeded()
            var samples: [Double] = []
            for _ in 0..<80 {
                let t0 = ContinuousClock.now
                editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
                window.displayIfNeeded()
                samples.append((ContinuousClock.now - t0).seconds * 1000)
                try? await Task.sleep(for: .milliseconds(15))
            }
            typing.append(contentsOf: samples)
            let sorted = samples.sorted()
            Log.perf.info("IDE 输入基准", ["wrap": "\(wrap)", "p95": String(format: "%.2f", sorted[Int(Double(sorted.count) * 0.95)]), "max": String(format: "%.2f", sorted.last ?? 0)])
            // 滚动:每步下移 12 行并绘制
            if !wrap {
                var frames: [Double] = []
                let step = (editor.textView.font?.pointSize ?? 12) * 1.6 * 12
                for index in 0..<200 {
                    let t0 = ContinuousClock.now
                    editor.textView.scroll(NSPoint(x: 0, y: step * Double(index)))
                    window.displayIfNeeded()
                    frames.append((ContinuousClock.now - t0).seconds * 1000)
                }
                scrollAverage = frames.reduce(0, +) / Double(max(frames.count, 1))
            }
            window.close()
        }
        let sorted = typing.sorted()
        setValue("ide.typing-p95", sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)], "50k 行,换行与不换行共 \(sorted.count) 次按键")
        setValue("ide.typing-max", sorted.last ?? 0, "同上")
        setValue("ide.scroll-frame", scrollAverage, "200 步同步滚动+绘制的平均耗时(不含显示器等待)")
    }

    // MARK: 语法

    private func benchSyntax(bigText: String) async {
        currentStep = "tree-sitter 解析"
        let engine = HighlightEngine()
        let full = ContinuousClock.now
        await engine.rebuild(text: bigText, language: .swift)
        let fullMs = (ContinuousClock.now - full).seconds * 1000
        let usesTree = await engine.usesTreeSitter
        setValue("ide.syntax-full", fullMs, usesTree ? "tree-sitter 全量" : "退回词法(未使用 tree-sitter)")
        // 增量:在中部各插入一个字符,量重解析耗时,取中位数(字符串提前构造,不计入耗时)
        var text = bigText as NSString
        let midpoint = text.length / 2
        var variants: [String] = []
        for index in 0..<20 {
            text = text.replacingCharacters(in: NSRange(location: midpoint + index, length: 0), with: "x") as NSString
            variants.append(String(text))
        }
        var samples: [Double] = []
        var parseOnly: [Double] = []
        for variant in variants {
            let t0 = ContinuousClock.now
            await engine.rebuild(text: variant, language: .swift)
            samples.append((ContinuousClock.now - t0).seconds * 1000)
            parseOnly.append(await engine.lastParseMs)
        }
        let parseMedian = parseOnly.sorted()[parseOnly.count / 2]
        let incremental = await engine.lastParseWasIncremental
        let median = samples.sorted()[samples.count / 2]
        setValue("ide.syntax-incremental", median, incremental ? "20 次中位数(增量;其中纯解析 \(String(format: "%.1f", parseMedian)) ms,其余为 UTF-16 拷贝与差分)" : "20 次中位数(未走增量)")
    }

    // MARK: 快速打开与搜索

    private func benchPaletteAndSearch(root: String) async {
        currentStep = "快速打开与全文搜索"
        let files = await Task.detached(priority: .userInitiated) { WorkspaceFiles.index(root: root) }.value
        var worst = 0.0
        var perKey: [String] = []
        for query in ["m", "ma", "mai", "main", "main.", "main.sw"] {
            let t0 = ContinuousClock.now
            _ = IDEQuickOpen.rank(query: query, files: files, recents: [])
            let ms = (ContinuousClock.now - t0).seconds * 1000
            perKey.append("\(query)=\(Int(ms))")
            worst = max(worst, ms)
        }
        setValue("ide.quick-open-key", worst, "\(files.count) 个文件,逐字输入各键耗时(ms):\(perKey.joined(separator: " "))")
        // 首次搜索会在后台建立三元组索引并回退全量扫描;索引就绪后再搜另一个词,取这次(日常使用的稳态)
        let coldStarted = ContinuousClock.now
        _ = await WorkspaceSearch.searchRoots([(root, files)], options: SearchOptions(query: "Block12"))
        let cold = (ContinuousClock.now - coldStarted).seconds * 1000
        await SearchIndexRegistry.shared.index(for: root).waitUntilReady()
        let started = ContinuousClock.now
        let output = await WorkspaceSearch.searchRoots([(root, files)], options: SearchOptions(query: "Block37"))
        let warm = (ContinuousClock.now - started).seconds * 1000
        setValue("ide.search-first", warm, "索引就绪后整次搜索(接口不分批,\(output.files.count) 个命中文件,扫描 \(output.scannedFiles) 个);首次无索引 \(Int(cold)) ms")
    }

    // MARK: 窗口内:标签切换与内存

    private func benchWindows(root: String, lab: String, bigPath: String, baseline: Double) async {
        currentStep = "IDE 窗口:标签与内存"
        let manager = IDEWindowManager.shared
        for leftover in manager.registry.windows { manager.controller(for: leftover)?.window?.close() }
        try? await Task.sleep(for: .milliseconds(800))
        let beforeEmpty = footprintMB()
        let model = manager.open(root: root, forceNew: true)
        guard let controller = manager.controller(for: model) else { return }
        try? await Task.sleep(for: .milliseconds(800))
        setValue("ide.memory-empty-window", max(footprintMB() - beforeEmpty, 0), "新开一个空窗口(含 SwiftUI 外壳)", unit: .megabytes)

        // 冷:依次首次打开 6 个文件;热:在已打开的两个标签间来回
        let samples = (1...6).map { "\(lab)/lang/\($0)" }
        let langFiles = (try? FileManager.default.contentsOfDirectory(atPath: lab + "/lang").sorted().map { lab + "/lang/" + $0 }) ?? samples
        let beforeFiles = footprintMB()
        var cold: [Double] = []
        for path in langFiles.prefix(10) {
            let t0 = ContinuousClock.now
            model.openFile(path, preview: false)
            settleUI(controller.window)
            cold.append((ContinuousClock.now - t0).seconds * 1000)
            try? await Task.sleep(for: .milliseconds(150))
        }
        if !cold.isEmpty { setValue("ide.tab-switch-cold", cold.sorted()[cold.count / 2], "首次打开 \(cold.count) 个文件的中位数") }
        try? await Task.sleep(for: .milliseconds(500))
        setValue("ide.memory-10-files", max(footprintMB() - beforeFiles, 0), "打开 \(min(langFiles.count, 10)) 个普通文件", unit: .megabytes)

        if langFiles.count >= 2 {
            var warm: [Double] = []
            for index in 0..<20 {
                let t0 = ContinuousClock.now
                model.openFile(langFiles[index % 2], preview: false)
                settleUI(controller.window)
                warm.append((ContinuousClock.now - t0).seconds * 1000)
                try? await Task.sleep(for: .milliseconds(60))
            }
            let parts = stride(from: settleBreakdown.count - 60, to: settleBreakdown.count, by: 3).map { Array(settleBreakdown[$0..<$0 + 3]) }
            func median(_ column: Int) -> Int { Int(parts.map { $0[column] }.sorted()[parts.count / 2]) }
            setValue("ide.tab-switch-warm", warm.sorted()[warm.count / 2], "已打开标签间来回切换 20 次的中位数(运行循环 \(median(0)) / 布局 \(median(1)) / 绘制 \(median(2)) ms)")
        }

        let before50k = footprintMB()
        model.openFile(bigPath, preview: false)
        try? await Task.sleep(for: .milliseconds(1500))
        setValue("ide.memory-50k", max(footprintMB() - before50k, 0), "打开 Big50k.swift", unit: .megabytes)

        // 3 个窗口空闲占用(绝对值):先关闭前面所有窗口并回收空闲页,再新开 3 个窗口各打开 3 个普通文件
        for window in manager.registry.windows { manager.controller(for: window)?.window?.close() }
        try? await Task.sleep(for: .seconds(1))
        _ = malloc_zone_pressure_relief(nil, 0)
        let afterClose = footprintMB()
        let threeWindows = (0..<3).map { _ in manager.open(root: root, forceNew: true) }
        for model in threeWindows {
            for path in langFiles.prefix(3) { model.openFile(path, preview: false) }
            manager.controller(for: model)?.window?.displayIfNeeded()
        }
        try? await Task.sleep(for: .seconds(2))
        _ = malloc_zone_pressure_relief(nil, 0)
        let withThree = footprintMB()
        setValue("ide.memory-3-windows", max(withThree - afterClose, 0), "3 个 IDE 窗口各开 3 个文件:绝对占用 \(Int(withThree)) MB,关闭全部窗口后 \(Int(afterClose)) MB(基线 \(Int(baseline)) MB)", unit: .megabytes)
        await soak(manager: manager, windows: threeWindows, files: langFiles)
        for window in manager.registry.windows { manager.controller(for: window)?.window?.close() }
    }

    /// 3 窗口浸泡:三个阶段(切标签 / 开关性能 HUD / 开关底部面板)各占三分之一时长,
    /// 每个阶段单独量内存漂移(先让每个窗口把全部文件各打开一遍并回收分配器空闲页再取起点),便于定位漂移来源。
    private func soak(manager: IDEWindowManager, windows: [IDEWindowModel], files: [String]) async {
        currentStep = "IDE 3 窗口浸泡"
        let seconds = Double(ProcessInfo.processInfo.environment["OMA_IDE_SOAK_SECONDS"] ?? "") ?? 24
        guard !files.isEmpty, !windows.isEmpty else { return }
        let phases: [(name: String, action: (IDEWindowModel, Int) -> Void)] = [
            ("切标签", { model, round in _ = model.openFile(files[round % files.count], preview: false) }),
            ("性能HUD", { model, _ in model.perfHUDVisible.toggle() }),
            ("底部面板", { model, _ in model.togglePanel() }),
        ]
        // 热身:每个窗口把全部文件轮流打开两遍并逐个绘制(每个被挂载的编辑器首次显示才分配图层缓冲,属于一次性成本)
        for _ in 0..<2 {
            for path in files {
                for model in windows {
                    model.openFile(path, preview: false)
                    settleUI(manager.controller(for: model)?.window)
                }
            }
        }
        for model in windows {
            // 面板、HUD 各显示一次(终端的首次创建是一次性成本,不算漂移),再复位
            model.perfHUDVisible = true
            model.showPanel(.terminal)
            manager.controller(for: model)?.window?.displayIfNeeded()
        }
        try? await Task.sleep(for: .seconds(2))
        for model in windows { model.perfHUDVisible = false; model.panelVisible = false }
        try? await Task.sleep(for: .seconds(1))
        // 窗口服务器的图层缓冲(IOSurface)在窗口真正被合成后才异步分配,约几秒后进入平台期;
        // 先持续切标签 8 秒让它稳定,否则会把这部分一次性成本算成漂移(vmmap 实测:malloc 已分配量全程只涨不到 1 MB)
        let settleDeadline = ContinuousClock.now + .seconds(8)
        var warmRound = 0
        while ContinuousClock.now < settleDeadline, !cancelled {
            for (index, model) in windows.enumerated() {
                model.openFile(files[(warmRound + index) % files.count], preview: false)
                settleUI(manager.controller(for: model)?.window)
            }
            warmRound += 1
            try? await Task.sleep(for: .milliseconds(150))
        }
        let overallStart = await settledFootprintMB()
        var peak = overallStart
        var parts: [String] = []
        var rounds = 0
        for phase in phases where !cancelled {
            let start = await settledFootprintMB()
            let deadline = ContinuousClock.now + .seconds(seconds / Double(phases.count))
            var round = 0
            while ContinuousClock.now < deadline, !cancelled {
                for (index, model) in windows.enumerated() {
                    phase.action(model, round + index)
                    manager.controller(for: model)?.window?.displayIfNeeded()
                }
                round += 1
                peak = max(peak, footprintMB())
                try? await Task.sleep(for: .milliseconds(150))
            }
            // 把各窗口复位到统一状态再取终点
            for model in windows { model.perfHUDVisible = false; model.panelVisible = false }
            parts.append("\(phase.name) \(round) 轮 \(String(format: "%+.0f", await settledFootprintMB() - start)) MB")
            rounds += round
        }
        let end = await settledFootprintMB()
        setValue("ide.soak-drift", max(end - overallStart, 0), "\(windows.count) 个窗口 \(Int(seconds)) 秒 \(rounds) 轮;起点 \(Int(overallStart)) MB,峰值 \(Int(peak)) MB,终点 \(Int(end)) MB;分阶段:\(parts.joined(separator: ","))", unit: .megabytes)
    }

    // MARK: 工具

    /// 让一次模型变更真正落到视图:转一圈运行循环(处理 SwiftUI 的更新调度)后布局并绘制。
    private func settleUI(_ window: NSWindow?) {
        let t0 = ContinuousClock.now
        RunLoop.main.run(mode: .default, before: Date())
        let t1 = ContinuousClock.now
        window?.contentView?.layoutSubtreeIfNeeded()
        let t2 = ContinuousClock.now
        window?.displayIfNeeded()
        let t3 = ContinuousClock.now
        settleBreakdown.append((t1 - t0).seconds * 1000)
        settleBreakdown.append((t2 - t1).seconds * 1000)
        settleBreakdown.append((t3 - t2).seconds * 1000)
    }

    /// 取「静止后」的内存:先把分配器空闲页还给系统并等一会儿让延迟释放完成,再取三次读数的最小值,降低噪声。
    private func settledFootprintMB() async -> Double {
        try? await Task.sleep(for: .seconds(1))
        _ = malloc_zone_pressure_relief(nil, 0)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(400))
            best = min(best, footprintMB())
        }
        return best
    }

    private func footprintMB() -> Double { ResourceSampler.shared.sample()?.footprintMB ?? 0 }

    private func setValue(_ id: String, _ value: Double, _ detail: String, unit: DemoMetricUnit = .milliseconds) {
        report.record(updated(id) { $0.value = value; $0.detail = detail })
        Log.perf.info("IDE 基准项", ["id": id, "value": String(format: "%.2f", value), "unit": unit.suffix, "detail": detail])
    }
}
