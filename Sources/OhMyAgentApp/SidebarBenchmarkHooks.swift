// @author ixxxxoooo
// 项目栏流畅度基准钩子(仅脚本化验证用,不影响正常使用):
// `OMA_SIDEBAR_SWEEP=scroll,expand,hover,status,unrelated|all`,配合 `OMA_DEMO_SIDEBAR_PROJECTS=50` 的多项目压力数据。
// - idle:空转对照组(只有驱动循环本身的开销,用于扣除基线);
// - scroll:对项目栏的 `NSScrollView` 逐帧上下滚动;
// - expand:反复「折叠全部 ⇄ 展开全部」;
// - hover:合成鼠标移动(会移动真实光标,需窗口在前台)扫过整列;
// - status:每帧翻转一个会话的注意力状态(模拟运行中/空闲更新);
// - unrelated:每帧写右栏拖动临时宽度(与项目栏无关的状态变化,期望项目栏 body 重算为 0)。
// 每项输出一条 perf 日志「项目栏基准」:帧数、平均/最长帧间隔、掉帧数、主线程每帧忙碌时间、各视图 body 次数。
// 主线程忙碌时间用 RunLoop 观察者统计「被唤醒 → 再次休眠」的时长,代表真实的主线程开销(比帧间隔更灵敏)。

import AppKit
import ChatKit
import OMLog
import QuartzCore
import WorkbenchKit

/// 项目栏基准的纯计算部分(与 AppKit 解耦,便于测试)。
enum SidebarSweepPlan {
    /// 基准项目。
    enum Kind: String, CaseIterable {
        case idle, scroll, expand, hover, status, unrelated
    }

    /// 解析 `OMA_SIDEBAR_SWEEP`。
    /// - Parameter raw: 环境变量原文(`all` 或逗号分隔)
    /// - Returns: 要运行的项目(保持固定顺序);空串/非法返回空数组
    static func kinds(from raw: String?) -> [Kind] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return [] }
        if raw == "all" || raw == "1" { return Kind.allCases }
        let picked = Set(raw.split(separator: ",").compactMap { Kind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) })
        return Kind.allCases.filter(picked.contains)
    }

    /// 汇总主线程忙碌时段。
    /// - Parameters:
    ///   - periods: 每个 RunLoop 迭代的忙碌毫秒数
    ///   - frames: 同期帧数(≥1)
    /// - Returns: 每帧平均忙碌毫秒与单次最长忙碌毫秒
    static func summarizeBusy(_ periods: [Double], frames: Int) -> (perFrameMs: Double, maxMs: Double) {
        guard !periods.isEmpty, frames > 0 else { return (0, 0) }
        return (periods.reduce(0, +) / Double(frames), periods.max() ?? 0)
    }

    /// 合成悬停的光标路径:在 `[top, bottom]` 之间来回扫过 `cycles` 次。
    /// - Parameters:
    ///   - top: 起点 y
    ///   - bottom: 终点 y
    ///   - steps: 单程步数
    ///   - cycles: 往返次数
    static func hoverPath(top: Double, bottom: Double, steps: Int, cycles: Int) -> [Double] {
        SweepPlan.zigzag(low: min(top, bottom), high: max(top, bottom), steps: steps, cycles: cycles)
    }
}

/// 主线程忙碌时间统计:统计 RunLoop 每次「唤醒 → 休眠」之间的时长。
@MainActor
private final class RunLoopBusyMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt: CFAbsoluteTime = 0
    private(set) var periods: [Double] = []

    /// 开始统计。
    func start() {
        periods = []
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.handle(activity) }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// 结束统计。
    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func handle(_ activity: CFRunLoopActivity) {
        if activity.contains(.afterWaiting) {
            wokeAt = CFAbsoluteTimeGetCurrent()
        } else if activity.contains(.beforeWaiting), wokeAt > 0 {
            periods.append((CFAbsoluteTimeGetCurrent() - wokeAt) * 1000)
            wokeAt = 0
        }
    }
}

@MainActor
enum SidebarBenchmarkHooks {
    /// 按环境变量依次执行项目栏基准。
    /// - Parameters:
    ///   - env: 环境变量
    ///   - workbench: 工作台模型
    static func runIfRequested(env: [String: String], workbench: WorkbenchModel) async {
        let kinds = SidebarSweepPlan.kinds(from: env["OMA_SIDEBAR_SWEEP"])
        guard !kinds.isEmpty else { return }
        // 等界面落定(会话挂载、侧栏首次布局)
        try? await Task.sleep(for: .seconds(2.5))
        let projects = workbench.workspaceProjects.count
        let rows = workbench.workspaceProjects.reduce(0) { $0 + min($1.sessions.count, 5) + 1 }
        Log.perf.info("基准阶段", ["phase": "项目栏基准开始", "projects": "\(projects)", "rows": "\(rows)"])
        for kind in kinds {
            switch kind {
            case .idle: await idle()
            case .scroll: await scroll(workbench)
            case .expand: await expand(workbench, projects: projects)
            case .hover: await hover(workbench)
            case .status: await status()
            case .unrelated: await unrelated(workbench)
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        Log.perf.info("基准阶段", ["phase": "项目栏基准结束"])
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.resizable) && $0.level == .normal }
    }

    private static func nextFrame() async { try? await Task.sleep(for: .milliseconds(16)) }

    /// 项目栏的滚动视图:窗口坐标里位于左侧栏范围内、文档最高的那个。
    private static func sidebarScrollView(in root: NSView, width: Double) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ node: NSView) {
            if let scroll = node as? NSScrollView, let document = scroll.documentView, !scroll.isHiddenOrHasHiddenAncestor {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.midX < width + 40, document.frame.height > (best?.documentView?.frame.height ?? 0) { best = scroll }
            }
            node.subviews.forEach(visit)
        }
        visit(root)
        return best
    }

    /// 在 `body` 执行期间采样帧间隔 + 主线程忙碌时间 + 各视图 body 重算次数,并输出日志。
    private static func measure(_ kind: SidebarSweepPlan.Kind, extra: [String: String] = [:], _ body: () async -> Void) async {
        guard let view = mainWindow?.contentView else {
            Log.perf.warning("项目栏基准:没有可用的主窗口", ["kind": kind.rawValue])
            return
        }
        let start = ContinuousClock.now
        let meter = RunLoopBusyMeter()
        meter.start()
        let sampler = SweepSampler(view: view)
        await body()
        let frames = sampler.stop()
        meter.stop()
        let busy = SidebarSweepPlan.summarizeBusy(meter.periods, frames: frames.frames)
        let counts = PanelToggleProbe.bodyCounts(since: start).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        var fields: [String: String] = [
            "kind": kind.rawValue, "frames": "\(frames.frames)", "avgMs": String(format: "%.1f", frames.avgMs),
            "maxMs": String(format: "%.1f", frames.maxMs), "hitches": "\(frames.hitches)",
            "busyPerFrameMs": String(format: "%.2f", busy.perFrameMs), "busyMaxMs": String(format: "%.1f", busy.maxMs),
            "bodies": counts,
        ]
        fields.merge(extra) { _, new in new }
        Log.perf.info("项目栏基准", fields)
    }

    // MARK: 各项

    private static func idle() async {
        await measure(.idle) {
            for _ in 0..<120 { await nextFrame() }
        }
    }

    private static func scroll(_ workbench: WorkbenchModel) async {
        guard let root = mainWindow?.contentView, let scroll = sidebarScrollView(in: root, width: workbench.layout.leftWidth),
              let document = scroll.documentView else {
            Log.perf.warning("项目栏基准:找不到项目栏滚动视图", ["kind": "scroll"])
            return
        }
        let travel = max(0, document.frame.height - scroll.contentView.bounds.height)
        guard travel > 200 else {
            Log.perf.warning("项目栏基准:内容不足以滚动", ["kind": "scroll", "travel": String(format: "%.0f", travel)])
            return
        }
        await measure(.scroll, extra: ["travel": String(format: "%.0f", travel)]) {
            for offset in SweepPlan.zigzag(low: 0, high: travel, steps: 90, cycles: 3) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                await nextFrame()
            }
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func expand(_ workbench: WorkbenchModel, projects: Int) async {
        let original = workbench.allProjectsCollapsed
        await measure(.expand, extra: ["projects": "\(projects)", "toggles": "12"]) {
            for index in 0..<12 {
                workbench.setAllProjectsCollapsed(index % 2 == 0)
                // 留出动画与布局落定的时间(每次切换都单独计入掉帧)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        workbench.setAllProjectsCollapsed(original)
    }

    private static func hover(_ workbench: WorkbenchModel) async {
        guard let window = mainWindow, let screen = window.screen ?? NSScreen.main else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
        // 项目栏水平居中、垂直方向取标题区下方到窗口底部上方
        let frame = window.frame
        let x = frame.minX + min(workbench.layout.leftWidth, frame.width / 3) / 2
        let top = frame.maxY - 160, bottom = frame.minY + 80
        // CGEvent 的 y 轴向下,以主屏(坐标原点所在屏)顶部为原点
        let height = (NSScreen.screens.first ?? screen).frame.maxY
        let ys = SidebarSweepPlan.hoverPath(top: top, bottom: bottom, steps: 90, cycles: 3)
        var moved = false
        await measure(.hover) {
            for y in ys {
                let point = CGPoint(x: x, y: height - y)
                if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                    event.post(tap: .cghidEventTap)
                    moved = true
                }
                await nextFrame()
            }
        }
        if !moved { Log.perf.warning("项目栏基准:无法合成鼠标事件", ["kind": "hover"]) }
    }

    private static func status() async {
        let center = AttentionCenter.shared
        let id = "bench-status"
        await measure(.status, extra: ["updates": "120"]) {
            for index in 0..<120 {
                center.update(id: id, title: "bench", project: "bench", workspacePath: "/tmp/bench", sessionId: nil, running: index % 2 == 0, needsInput: false)
                await nextFrame()
            }
        }
        center.update(id: id, title: "bench", project: "bench", workspacePath: "/tmp/bench", sessionId: nil, running: false, needsInput: false)
        center.markRead(id)
    }

    private static func unrelated(_ workbench: WorkbenchModel) async {
        let base = PanelDimension.rightWidth.committed(in: workbench.layout)
        await measure(.unrelated, extra: ["writes": "180"]) {
            for value in SweepPlan.zigzag(low: PanelDimension.rightWidth.clamp(base - 60), high: PanelDimension.rightWidth.clamp(base + 60), steps: 45, cycles: 2) {
                workbench.panelDrag.update(value, for: .rightWidth)
                await nextFrame()
            }
        }
        workbench.commitPanelDrag(.rightWidth)
    }
}
