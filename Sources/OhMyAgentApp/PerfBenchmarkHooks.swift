// @author ixxxxoooo
// 性能基准调试钩子(仅脚本化验证用,不影响正常使用):
// `OMA_SWITCH_SESSIONS=N` 依次冷打开 N 个历史会话,再在已挂载的会话标签之间循环切换若干轮;
// 配合 `OMA_TOGGLE_LEFT/RIGHT`、`OMA_TOGGLE_COUNT` 与 `Scripts/perf-ui.sh` 汇总「侧栏切换/标签切换/时间线挂载/主线程卡顿」。

import AppKit
import Foundation
import OMLog
import WorkbenchKit

/// 一个待冷打开的历史会话。
struct BenchmarkSession: Equatable {
    let projectID: String
    let sessionId: String
    let title: String?
}

/// 基准计划(纯逻辑,便于测试)。
enum BenchmarkPlan {
    /// 从项目列表挑出最多 `count` 个历史会话:项目按列表顺序,项目内按缓存顺序;跳过已归档/已删除的会话。
    /// - Parameters:
    ///   - projects: 项目列表
    ///   - count: 需要的会话数(≤0 返回空)
    /// - Returns: 待打开的会话
    static func pick(from projects: [ProjectEntry], count: Int) -> [BenchmarkSession] {
        guard count > 0 else { return [] }
        var result: [BenchmarkSession] = []
        for project in projects where !project.isChatArea {
            for session in project.sessions where !session.sessionId.isEmpty
                && !project.archivedSessions.contains(session.sessionId) && !project.deletedSessions.contains(session.sessionId) {
                result.append(BenchmarkSession(projectID: project.id, sessionId: session.sessionId, title: session.title))
                if result.count >= count { return result }
            }
        }
        return result
    }
}

@MainActor
enum PerfBenchmarkHooks {
    /// 执行会话切换基准。
    /// - Parameters:
    ///   - workbench: 工作台模型
    ///   - count: 冷打开的会话数
    ///   - rounds: 已挂载标签之间循环切换的轮数
    static func switchSessions(workbench: WorkbenchModel, count: Int, rounds: Int = 3) async {
        for _ in 0..<50 where workbench.projects.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let plan = BenchmarkPlan.pick(from: workbench.projects, count: count)
        Log.perf.info("基准阶段", ["phase": "冷打开开始", "sessions": "\(plan.count)"])
        // OMA_SWITCH_SAMPLE_OUT=目录:逐帧采样窗口并分析切换瞬间的中间帧(见 IDEFrameSampler)
        let sampleDir = ProcessInfo.processInfo.environment["OMA_SWITCH_SAMPLE_OUT"]
        let window = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let sampler = sampleDir == nil ? nil : window?.contentView.map { IDEFrameSampler(view: $0) }
        defer {
            if let sampler, let sampleDir {
                try? sampler.finish(into: sampleDir).write(toFile: sampleDir + "/report.txt", atomically: true, encoding: .utf8)
            }
        }
        for item in plan {
            sampler?.mark("冷打开 \(item.title ?? item.sessionId)")
            workbench.openHistory(project: item.projectID, sessionId: item.sessionId, title: item.title)
            // 留出连接与回放时间,让每次冷打开互不重叠
            try? await Task.sleep(for: .milliseconds(2500))
        }
        let tabs = workbench.dock.allTabs.filter { if case .chat = $0.kind { return true } else { return false } }
        Log.perf.info("基准阶段", ["phase": "热切换开始", "tabs": "\(tabs.count)"])
        for _ in 0..<max(rounds, 1) {
            for tab in tabs {
                sampler?.mark("热切换 \(tab.title)")
                workbench.activateTab(tab.id)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        Log.perf.info("基准阶段", ["phase": "切换结束"])
    }
}
