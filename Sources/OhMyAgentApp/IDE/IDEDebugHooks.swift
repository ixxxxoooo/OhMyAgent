// @author ixxxxoooo
// IDE 模式调试钩子(自动化验证用,不抢焦点):
// - `OMA_IDE=1`:启动后打开 IDE 窗口(根目录取 `OMA_IDE_ROOT`,否则取当前项目);
// - `OMA_IDE_EXPAND=相对路径1|相对路径2`:打开后展开这些目录并定位到最后一个;
// - `OMA_IDE_OPEN_FILE=路径[:行]`:打开后在编辑器里打开该文件(相对路径取工作区根);
// - `OMA_IDE_SWEEP=N`:开关/切换基准,重复 N 轮「冷开 → 切回 Agent → 热切到 IDE → 关闭」,
//   perf 日志「IDE 窗口基准」记录每轮耗时与内存漂移(计划预算:热切换 ≤ 50ms、冷开 ≤ 250ms、20 轮漂移 ≤ 10MB)。

import AppKit
import Foundation
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
        if let raw = env["OMA_IDE_OPEN_FILE"], !raw.isEmpty {
            var path = raw
            var line: Int?
            if let colon = raw.lastIndex(of: ":"), let number = Int(raw[raw.index(after: colon)...]) { path = String(raw[..<colon]); line = number }
            workspace.model.openFile(absolute(path), line: line, preview: false)
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
    static func sweep(rounds: Int, root: String?) async {
        let manager = IDEWindowManager.shared
        let target = root ?? AppEnvironment.shared.workbench.selectedProject?.id
        let clock = ContinuousClock()
        var cold: [Double] = [], warm: [Double] = []
        // 预热一轮(分配器与首次布局的一次性开销不计入漂移)
        let warmup = manager.open(root: target, forceNew: true)
        manager.controller(for: warmup)?.window?.close()
        try? await Task.sleep(for: .milliseconds(500))
        let before = footprintMB()
        for round in 1...rounds {
            // 计入首帧:显示后强制同步排版与绘制,否则只量到「下单」的耗时
            let coldTime = clock.measure { let model = manager.open(root: target, forceNew: true); manager.controller(for: model)?.window?.displayIfNeeded() }
            await settle()
            manager.switchToAgent()
            await settle()
            let warmTime = clock.measure { manager.switchToIDE(); manager.controller(for: manager.registry.mostRecent ?? warmup)?.window?.displayIfNeeded() }
            await settle()
            if let model = manager.registry.mostRecent { manager.controller(for: model)?.window?.close() }
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
    }

    /// 让出若干个 RunLoop 轮次,等窗口动画与布局稳定。
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }
}
