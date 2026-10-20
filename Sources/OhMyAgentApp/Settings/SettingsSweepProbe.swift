// @author ixxxxoooo
// 设置页切换性能探针(调试钩子 `OMA_SETTINGS_SWEEP=轮数`):依次切换所有设置页,
// 每次记录「切换 → 首帧」耗时与随后的卡顿帧,输出 perf 日志「设置页切换」。

import AppKit
import OMLog

@MainActor
enum SettingsSweepProbe {
    /// 依次切换全部设置页若干轮。
    /// - Parameters:
    ///   - router: 设置路由
    ///   - rounds: 轮数(第一轮为冷切换,之后为热切换)
    static func run(router: SettingsRouter, rounds: Int) async {
        try? await Task.sleep(for: .seconds(2))
        for round in 0..<max(rounds, 1) {
            for page in SettingsPage.allCases {
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 })?.contentView else { return }
                let start = ContinuousClock.now
                router.page = page
                let sampler = FrameSampler(name: page.rawValue, start: start, view: view) { r in
                    let fields = ["page": r.name, "round": "\(round)", "firstFrameMs": String(format: "%.1f", r.firstFrameMs),
                                  "maxMs": String(format: "%.1f", r.maxMs), "hitches": "\(r.hitches)"]
                    if r.firstFrameMs > 50 { Log.perf.warning("设置页切换", fields) } else { Log.perf.info("设置页切换", fields) }
                }
                try? await Task.sleep(for: .milliseconds(900))
                sampler.finish()
            }
        }
        Log.perf.info("设置页切换基准完成", ["rounds": "\(rounds)"])
    }
}
