// @author ixxxxoooo
// 演示模式启动钩子:
// - `OMA_DEMO_OPEN_SESSIONS=<项目名>:<序号>,...`:启动后依次打开演示历史会话(如 `perf-longchat:1,perf-render:1`);
// - `OMA_DEMO_BENCH=all|open,load,copy,render,switching,memory`:自动打开「演示指标」标签并运行基准,
//   完成后写出 `demo-metrics.json/.md`;`OMA_DEMO_BENCH_EXIT=1` 时随后退出应用(`Scripts/demo-bench.sh` 使用)。

import ACPKit
import AppKit
import DemoKit
import Foundation
import OMLog
import WorkbenchKit

/// 演示启动钩子。
@MainActor
enum DemoLaunchHooks {
    /// 解析 `OMA_DEMO_OPEN_SESSIONS`。
    /// - Parameter raw: 环境变量原文
    /// - Returns: (项目名, 会话序号) 列表,非法项被忽略
    static func parseOpenSessions(_ raw: String?) -> [(project: String, index: Int)] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, let index = Int(parts[1]), index > 0 else { return nil }
            return (parts[0], index)
        }
    }

    /// 按环境变量执行钩子(仅演示模式)。
    /// - Parameters:
    ///   - workbench: 工作台
    ///   - env: 环境变量
    static func run(workbench: WorkbenchModel, env: [String: String]) async {
        guard DemoLaunch.isActive else { return }
        for item in parseOpenSessions(env["OMA_DEMO_OPEN_SESSIONS"]) {
            guard let project = workbench.projects.first(where: { $0.name == item.project }) else {
                Log.app.warning("演示钩子:找不到项目", ["project": item.project])
                continue
            }
            let id = "demo-\(item.project)-\(item.index)"
            workbench.openHistory(project: project.id, sessionId: id, title: DemoHistory.session(id: id)?.title)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let categories = DemoBenchmarkCatalog.categories(from: env["OMA_DEMO_BENCH"]) {
            workbench.openDemoMetrics()
            try? await Task.sleep(for: .seconds(1.5))
            await DemoBenchmarkRunner.shared.run(categories: categories)
            if env["OMA_DEMO_BENCH_EXIT"] == "1" { NSApp.terminate(nil) }
        }
    }
}
