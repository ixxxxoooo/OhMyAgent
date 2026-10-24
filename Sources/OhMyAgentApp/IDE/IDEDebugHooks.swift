// @author ixxxxoooo
// IDE 模式调试钩子(自动化验证用,不抢焦点):
// - `OMA_IDE=1`:启动后打开 IDE 窗口(根目录取 `OMA_IDE_ROOT`,否则取当前项目);
// - `OMA_IDE_EXPAND=相对路径1|相对路径2`:打开后展开这些目录并定位到最后一个;
// - `OMA_IDE_OPEN_FILE=路径[:行]`:打开后在编辑器里打开该文件(相对路径取工作区根);
// - `OMA_IDE_SIDEBAR=explorer|search|scm`:启动后切到该侧栏视图;`OMA_IDE_QUERY=词` 预填搜索词(配合 search);
// - `OMA_IDE_PANEL=terminal|problems|output`:启动后显示底部面板并切到该标签页;
// - `OMA_IDE_PALETTE=<输入>`:启动后打开命令面板并预填输入(如 `>保存`、`:12`、`main`);
// - `OMA_IDE_OPEN_DIFF=路径`:打开后在编辑器里打开该文件的 Diff 标签;
// - `OMA_IDE_EDITOR_ACTIONS=动作1;动作2`:打开文件后依次执行编辑器动作(`goto:行`、`selectlines:起-止`、`inline:指令`(⌘K 行内编辑)、`review:旧文本路径`(行内 Diff 审阅预览)、`inlineAccept`/`inlineReject`、`foldline:行`、`fold`、`unfold`、`foldAll`、`unfoldAll`、`nextOcc`、`type:文本`、`complete`、`hover:行:列`、`sig`、`actions`、`format`、`refs`、`wait:毫秒`);
// - `OMA_IDE_SWEEP=N`:开关/切换基准,重复 N 轮「冷开 → 切回 Agent → 热切到 IDE → 关闭」,
//   perf 日志「IDE 窗口基准」记录每轮耗时与内存漂移(计划预算:热切换 ≤ 50ms、冷开 ≤ 250ms、20 轮漂移 ≤ 10MB)。

import AppKit
import Foundation
import DiffKit
import EditorCore
import EditorKit
import IDEKit
import OMLog

@MainActor
enum IDEDebugHooks {
    /// 按环境变量执行钩子(无相关变量时立即返回)。
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let root = env["OMA_IDE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        if let raw = env["OMA_IDE_SWEEP"], let rounds = Int(raw), rounds > 0 {
            try? await Task.sleep(for: .seconds(2))
            await sweep(rounds: rounds, root: root)
        } else if env["OMA_IDE"] == "1" {
            try? await Task.sleep(for: .milliseconds(800))
            let model = IDEWindowManager.shared.open(root: root ?? AppEnvironment.shared.workbench.selectedProject?.id)
            if let workspace = IDEWindowManager.shared.controller(for: model)?.workspace { await prepare(workspace, env: env) }
        }
    }

    /// 窗口打开后按 `OMA_IDE_EXPAND` / `OMA_IDE_OPEN_FILE` 预置界面状态。
    private static func prepare(_ workspace: IDEWorkspace, env: [String: String]) async {
        guard let base = workspace.root else { return }
        func absolute(_ path: String) -> String { path.hasPrefix("/") ? path : base + "/" + path }
        workspace.configureTree()
        if let raw = env["OMA_IDE_EXPAND"] {
            let paths = raw.split(separator: "|").map { absolute(String($0)) }
            for path in paths {
                // 逐级展开祖先,否则深层目录会被折叠的上级藏住
                var current = base
                for part in path.dropFirst(base.count).split(separator: "/") { current += "/" + part; workspace.tree.expand(current) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            if let last = paths.last { workspace.revealPath = last }
        }
        if let raw = env["OMA_IDE_SIDEBAR"], let view = IDESidebarView(rawValue: raw) { workspace.model.selectSidebar(view) }
        if let query = env["OMA_IDE_QUERY"], !query.isEmpty { workspace.search.root = base; workspace.search.query = query }
        if let raw = env["OMA_IDE_PANEL"], let tab = IDEPanelTab(rawValue: raw) {
            workspace.model.showPanel(tab)
            if tab == .terminal { workspace.newTerminal() }
        }
        if let raw = env["OMA_IDE_PALETTE"] {
            workspace.palette.present(prefix: raw, root: workspace.root)
        }
        if let raw = env["OMA_IDE_OPEN_FILE"], !raw.isEmpty {
            var path = raw
            var line: Int?
            if let colon = raw.lastIndex(of: ":"), let number = Int(raw[raw.index(after: colon)...]) { path = String(raw[..<colon]); line = number }
            workspace.model.openFile(absolute(path), line: line, preview: false)
        }
        if let raw = env["OMA_IDE_OPEN_DIFF"], !raw.isEmpty { workspace.model.openDiff(absolute(raw)) }
        if let raw = env["OMA_IDE_EDITOR_ACTIONS"], !raw.isEmpty { await runEditorActions(raw) }
        await IDESwitchProbe.run(workspace, env: env)
        if let raw = env["OMA_IDE_EDITOR_SWEEP"], let seconds = Double(raw), seconds > 0 { await runEditorSweep(seconds: seconds) }
    }

    /// `OMA_IDE_EDITOR_SWEEP=秒数`:在真实 IDE 窗口里对第一个原生编辑器匀速滚动,用显示链接采样帧间隔,
    /// 结束输出一条 perf 日志「编辑器滚动基准」(帧数、平均/最长帧间隔、超过 33ms 的掉帧数)。
    /// 与 `Scripts/editor-bench.sh` 的合成素材基准互补:这里量的是带 SwiftUI 外壳的整窗口真实表现。
    private static func runEditorSweep(seconds: Double) async {
        for _ in 0..<100 where firstNativeEditor() == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let editor = firstNativeEditor() else {
            Log.perf.warning("编辑器滚动基准:没有可用的原生编辑器")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        let row = Double(editor.model.lineHeight)
        let nominal = 1000.0 / Double(max(editor.window?.screen?.maximumFramesPerSecond ?? 60, 30))
        let sampler = SweepSampler(view: editor)
        let started = ContinuousClock.now
        var offset = 0.0
        while (ContinuousClock.now - started) < .seconds(seconds) {
            offset += row * 2
            editor.scroll(y: CGFloat(offset.truncatingRemainder(dividingBy: max(Double(editor.model.contentHeight) - 700, row))))
            try? await Task.sleep(for: .milliseconds(Int(nominal)))
        }
        let result = sampler.stop()
        Log.perf.info("编辑器滚动基准", ["frames": "\(result.frames)", "avgMs": String(format: "%.2f", result.avgMs),
                                  "maxMs": String(format: "%.1f", result.maxMs), "hitches": "\(result.hitches)", "nominalMs": String(format: "%.1f", nominal)])
    }

    /// 在所有窗口里找原生编辑器(应用在后台时没有键盘焦点);优先取正在编辑 `OMA_IDE_OPEN_FILE` 的那个。
    private static func firstNativeEditor() -> OMEditorView? {
        var found: [OMEditorView] = []
        func search(_ view: NSView) {
            if let editor = view as? OMEditorView, !editor.isHiddenOrHasHiddenAncestor { found.append(editor) }
            for sub in view.subviews { search(sub) }
        }
        for window in NSApp.windows { if let content = window.contentView { search(content) } }
        if let raw = ProcessInfo.processInfo.environment["OMA_IDE_OPEN_FILE"], !raw.isEmpty {
            let path = raw.split(separator: ":").first.map(String.init) ?? raw
            if let match = found.first(where: { $0.model.fileName == path }) { return match }
        }
        return found.first
    }

    /// 在所有窗口里找第一个可见的代码编辑器(应用在后台时没有键盘焦点,`activeEditor` 为空)。
    private static func firstEditor() -> CodeEditorView? {
        func search(_ view: NSView) -> CodeEditorView? {
            if let editor = view as? CodeEditorView, !editor.isHiddenOrHasHiddenAncestor { return editor }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        for window in NSApp.windows { if let content = window.contentView, let found = search(content) { return found } }
        return nil
    }

    /// 执行 `OMA_IDE_EDITOR_ACTIONS` 的动作序列(验证折叠、多光标等编辑器行为用)。
    private static func runEditorActions(_ raw: String) async {
        try? await Task.sleep(for: .milliseconds(1500))
        for token in raw.split(separator: ";").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            if parts.first == "wait" { try? await Task.sleep(for: .milliseconds(Int(argument) ?? 500)); continue }
            // 文件刚打开时编辑器尚未创建:最多等 10 秒再执行动作(wait 之外的动作才需要编辑器)。
            for _ in 0..<100 where OMEditorView.activeEditor() == nil && firstNativeEditor() == nil && firstEditor() == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // 原生引擎(native2)的编辑器:动作经 `EditorRouter` 路由,并补充查找/空白渲染等原生专属动作。
            if let native = firstNativeEditor() ?? OMEditorView.activeEditor() {
                switch parts.first ?? "" {
                case "goto": native.goToLine(line: Int(argument) ?? 1, column: 1)
                case "selectlines":
                    // selectlines:起-止(1 起,含):选中这些行,供 ⌘K 行内编辑
                    let range = argument.split(separator: "-").compactMap { Int($0) }
                    if let first = range.first {
                        let rope = native.model.document.snapshot
                        let low = min(max(first - 1, 0), rope.lineCount - 1), high = min(max((range.last ?? first) - 1, low), rope.lineCount - 1)
                        native.model.setSelections(SelectionSet([Selection(anchor: rope.lineStart(low), head: rope.lineStart(high) + rope.lineLength(high))]))
                    }
                case "inline": native.inlineEdit.debugRun(argument)
                case "review":
                    // review:旧文本文件路径:以它为「Agent 改动前」,在当前编辑器里展示行内 Diff 审阅
                    if let old = try? String(contentsOfFile: argument, encoding: .utf8) {
                        let diff = LineDiff.diff(old: old, new: native.model.document.text())
                        let actions = [NativeDiffAction(title: "Keep") { _ in }, NativeDiffAction(title: "Revert") { _ in }]
                        native.inlineReview.show(diff: diff, title: { _ in "Agent changes" }, actions: actions)
                    }
                case "inlineAccept": native.inlineEdit.accept()
                case "inlineReject": native.inlineEdit.reject()
                case "foldline": native.model.fold(line: max((Int(argument) ?? 1) - 1, 0))
                case "fold": native.perform(.fold)
                case "unfold": native.perform(.unfold)
                case "foldAll": native.perform(.foldAll)
                case "unfoldAll": native.perform(.unfoldAll)
                case "nextOcc": native.perform(.addNextOccurrence)
                case "find": native.showFind(); native.setFindQuery(argument)
                case "findClose": native.hideFind()
                case "ws": native.whitespaceRendering = WhitespaceRendering(rawValue: argument) ?? .all
                case "type": native.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
                case "complete": native.languageController.triggerCompletion(auto: false)
                case "hover":
                    // hover:行:列(1 起):把光标移到该处并模拟鼠标驻留
                    let parts = argument.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 { native.goToLine(line: parts[0], column: parts[1]) }
                    native.languageController.debugShowHover(at: native.model.selections.primary.head)
                case "sig": native.languageController.triggerSignature()
                case "actions": native.languageController.showCodeActions()
                case "format": native.languageController.formatDocument()
                case "refs": native.languageController.findReferences()
                case "wait": try? await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
                default: Log.app.warning("编辑器动作:未知", ["action": token])
                }
                continue
            }
            guard let editor = CodeEditorView.activeEditor() ?? firstEditor() else {
                Log.app.warning("编辑器动作:没有活动编辑器", ["action": token])
                continue
            }
            switch parts.first ?? "" {
            case "goto": editor.goToLine(Int(argument) ?? 1)
            case "foldline": editor.fold(line: max((Int(argument) ?? 1) - 1, 0))
            case "fold": editor.perform(.fold)
            case "unfold": editor.perform(.unfold)
            case "foldAll": editor.perform(.foldAll)
            case "unfoldAll": editor.perform(.unfoldAll)
            case "nextOcc": editor.perform(.addNextOccurrence)
            case "type": editor.textView.insertText(argument, replacementRange: editor.textView.selectedRange())
            case "wait": try? await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
            default: Log.app.warning("编辑器动作:未知", ["action": token])
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// 当前进程物理占用(MB)。
    private static func footprintMB() -> Double {
        guard let usage = SystemResourceProbe().usage(pid: ProcessInfo.processInfo.processIdentifier) else { return -1 }
        return Double(usage.footprintBytes) / 1_048_576
    }

    /// 开关/切换基准。
    /// - Parameters:
    ///   - rounds: 轮数
    ///   - root: IDE 窗口的根目录;nil 取当前项目
    /// - Returns: 冷开/热切换中位数(毫秒)与内存漂移(MB)
    @discardableResult
    static func sweep(rounds: Int, root: String?) async -> (coldMedianMs: Double, warmMedianMs: Double, driftMB: Double) {
        let manager = IDEWindowManager.shared
        let target = root ?? AppEnvironment.shared.workbench.selectedProject?.id
        let clock = ContinuousClock()
        var cold: [Double] = [], warm: [Double] = []
        // 预热三轮(分配器、字体与首次布局的一次性开销不计入漂移)
        var warmup = manager.open(root: target, forceNew: true)
        for _ in 0..<3 {
            warmup = manager.open(root: target, forceNew: true)
            manager.controller(for: warmup)?.window?.displayIfNeeded()
            await settle()
            manager.controller(for: warmup)?.window?.close()
            await settle()
        }
        try? await Task.sleep(for: .milliseconds(500))
        let before = footprintMB()
        for round in 1...rounds {
            // 计入首帧:显示后强制同步排版与绘制,否则只量到「下单」的耗时
            // 记住本轮新开的窗口:应用在后台时窗口不会成为 key,`registry.mostRecent` 不可靠,不能靠它收尾
            var opened: IDEWindowModel?
            let coldTime = clock.measure { let model = manager.open(root: target, forceNew: true); opened = model; manager.controller(for: model)?.window?.displayIfNeeded() }
            await settle()
            manager.switchToAgent()
            await settle()
            let warmTime = clock.measure { manager.switchToIDE(); manager.controller(for: opened ?? warmup)?.window?.displayIfNeeded() }
            await settle()
            if let model = opened { manager.controller(for: model)?.window?.close() }
            await settle()
            cold.append(coldTime.seconds * 1000)
            warm.append(warmTime.seconds * 1000)
            Log.perf.info("IDE 窗口基准", ["round": "\(round)", "coldMs": String(format: "%.1f", cold[round - 1]), "warmMs": String(format: "%.1f", warm[round - 1]), "footprintMB": String(format: "%.1f", footprintMB()), "windows": "\(manager.openCount)"])
        }
        try? await Task.sleep(for: .milliseconds(500))
        let drift = footprintMB() - before
        let sortedCold = cold.sorted(), sortedWarm = warm.sorted()
        Log.perf.info("IDE 窗口基准汇总", [
            "rounds": "\(rounds)",
            "coldMedianMs": String(format: "%.1f", sortedCold[sortedCold.count / 2]), "coldMaxMs": String(format: "%.1f", sortedCold.last ?? 0),
            "warmMedianMs": String(format: "%.1f", sortedWarm[sortedWarm.count / 2]), "warmMaxMs": String(format: "%.1f", sortedWarm.last ?? 0),
            "driftMB": String(format: "%.1f", drift),
        ])
        return (sortedCold[sortedCold.count / 2], sortedWarm[sortedWarm.count / 2], drift)
    }

    /// 让出若干个 RunLoop 轮次,等窗口动画与布局稳定。
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }
}
