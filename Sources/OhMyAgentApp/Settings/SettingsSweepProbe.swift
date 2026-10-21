// @author ixxxxoooo
// 设置页切换性能探针(调试钩子 `OMA_SETTINGS_SWEEP=轮数`,0 表示只测常用页来回切换):依次切换所有设置页,
// 再在常用页之间来回切换;每次记录「切换 → 首帧」耗时(点击反馈)与随后的最长帧(新页面构建),输出 perf 日志「设置页切换」。

import AppKit
import OMLog

@MainActor
enum SettingsSweepProbe {
    /// 防重入
    private static var running = false
    /// 最近一次侧栏选中的时刻与「选中 → 开始换页」耗时(即高亮单独上屏所用时间)
    private static var selectAt: ContinuousClock.Instant?
    private static var lastShowDelayMs: Double?

    /// 侧栏选中变化时调用(仅基准运行时记录)。
    static func markSelect() {
        guard running else { return }
        selectAt = .now
        lastShowDelayMs = nil
    }

    /// 右侧开始换页时调用(仅基准运行时记录)。
    static func markShow() {
        guard running, let selectAt else { return }
        let elapsed = ContinuousClock.now - selectAt
        lastShowDelayMs = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    }

    /// 依次切换全部设置页若干轮。
    /// - Parameters:
    ///   - router: 设置路由
    ///   - rounds: 轮数(第一轮为冷切换,之后为热切换)
    static func run(router: SettingsRouter, rounds: Int) async {
        guard !running else { return }
        running = true
        defer { running = false }
        try? await Task.sleep(for: .seconds(2))
        // 对照组:不切页,只测采样器自身的首帧底噪
        for _ in 0..<5 {
            guard await measure(router: router, page: router.page, round: "noop") else { return }
        }
        for round in 0..<max(rounds, 0) {
            for page in SettingsPage.allCases {
                guard await measure(router: router, page: page, round: "\(round)") else { return }
            }
        }
        // 常用页之间来回切换(保活命中的典型场景)
        for _ in 0..<(rounds == 0 ? 12 : 3) {
            for page in [SettingsPage.general, .appearance, .editor, .terminal] {
                guard await measure(router: router, page: page, round: "revisit") else { return }
            }
        }
        Log.perf.info("设置页切换基准完成", ["rounds": "\(rounds)"])
    }

    /// 切到某页并采样 0.9 秒:首帧耗时即点击反馈延迟,最长帧反映新页面构建造成的卡顿。
    /// - Returns: 是否找到可采样的窗口
    private static func measure(router: SettingsRouter, page: SettingsPage, round: String) async -> Bool {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 })?.contentView else { return false }
        let start = ContinuousClock.now
        router.page = page
        let sampler = FrameSampler(name: page.rawValue, start: start, view: view) { r in
            let fields = ["page": r.name, "round": round, "firstFrameMs": String(format: "%.1f", r.firstFrameMs),
                          "maxMs": String(format: "%.1f", r.maxMs), "hitches": "\(r.hitches)",
                          "showDelayMs": lastShowDelayMs.map { String(format: "%.1f", $0) } ?? "-"]
            if r.firstFrameMs > 50 { Log.perf.warning("设置页切换", fields) } else { Log.perf.info("设置页切换", fields) }
        }
        try? await Task.sleep(for: .milliseconds(900))
        sampler.finish()
        return true
    }
}
