// @author ixxxxoooo
// 项目栏压力数据:演示模式下追加大量「多项目 × 多会话」的合成项目,用于测量左侧栏的滚动、展开、悬停与状态更新开销。
// 开关:`OMA_DEMO_SIDEBAR_PROJECTS=<项目数>`(默认关闭),`OMA_DEMO_SIDEBAR_SESSIONS=<每项目会话数>`(默认 40)。
// 合成项目是沙盒里真实存在的空目录(`sb-01`…),会话只存在于工作台缓存(不连接 Agent);重复应用是幂等的。

import Foundation
import WorkbenchKit

/// 项目栏压力数据生成器(无视图)。
public enum DemoSidebarStress {
    /// 合成项目目录名前缀
    public static let prefix = "sb-"
    /// 项目数上限(防止误填过大的值把演示沙盒撑爆)
    public static let maxProjects = 200
    /// 每项目会话数上限
    public static let maxSessions = 500

    /// 一份压力数据规格。
    public struct Spec: Equatable, Sendable {
        public let projects: Int
        public let sessionsEach: Int

        public init(projects: Int, sessionsEach: Int) {
            self.projects = min(max(projects, 0), DemoSidebarStress.maxProjects)
            self.sessionsEach = min(max(sessionsEach, 1), DemoSidebarStress.maxSessions)
        }
    }

    /// 从环境变量解析规格;未设置或项目数 ≤ 0 返回 nil。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func spec(environment: [String: String] = ProcessInfo.processInfo.environment) -> Spec? {
        guard let count = environment["OMA_DEMO_SIDEBAR_PROJECTS"].flatMap(Int.init), count > 0 else { return nil }
        let sessions = environment["OMA_DEMO_SIDEBAR_SESSIONS"].flatMap(Int.init) ?? 40
        return Spec(projects: count, sessionsEach: sessions)
    }

    /// 合成项目名:`sb-01`…(两位以上补零)。
    /// - Parameter index: 从 0 开始的序号
    public static func projectName(_ index: Int) -> String { prefix + String(format: "%02d", index + 1) }

    /// 把压力项目写进工作台状态:先移除旧的合成项目,再追加新的(幂等)。
    /// - Parameters:
    ///   - state: 工作台状态
    ///   - spec: 规格
    ///   - paths: 沙盒路径(合成项目目录创建在其 `projects` 下)
    ///   - now: 基准时间
    public static func apply(to state: inout WorkbenchState, spec: Spec, paths: DemoPaths, now: Date = Date()) throws {
        let directory = paths.projects
        state.projects.removeAll { $0.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && $0.name.hasPrefix(prefix) }
        let formatter = ISO8601DateFormatter()
        for index in 0..<spec.projects {
            let name = projectName(index)
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var entry = ProjectEntry(url: url, now: now.addingTimeInterval(-Double(index) * 600))
            entry.sessions = (0..<spec.sessionsEach).map { number in
                CachedSession(
                    sessionId: "\(name)-s\(number)", title: title(project: index, number: number),
                    updatedAt: formatter.string(from: now.addingTimeInterval(-Double(index * 37 + number * 53 + 1) * 60)))
            }
            // 每个项目置顶 1 条、归档 3 条,贴近真实使用的混合状态
            if spec.sessionsEach > 6 {
                entry.pinnedSessions = ["\(name)-s2"]
                entry.archivedSessions = (3...5).map { "\(name)-s\($0)" }
            }
            entry.collapsed = false
            state.projects.append(entry)
        }
    }

    /// 合成会话标题:中英文混合、长短不一,覆盖渐隐与截断路径。
    /// - Parameters:
    ///   - project: 项目序号
    ///   - number: 会话序号
    static func title(project: Int, number: Int) -> String {
        let samples = [
            "修复路由解析的大小写问题", "Refactor the session store", "为 Session 增加超时与重试", "review: 把 ACP 事件合批改成自适应窗口",
            "排查 CI 偶发失败", "梳理 AtlasCore 路由架构并给出拆分方案(含迁移步骤与回滚预案)", "Add unit tests for TimelineWindow",
            "整理发布说明", "perf: sidebar scroll hitch investigation", "把设置页拆成多个子页面",
        ]
        return "\(samples[(project * 7 + number) % samples.count]) #\(number + 1)"
    }
}
