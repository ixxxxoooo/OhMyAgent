// @author ygw
// 演示数据预置:工作台状态(多项目、置顶/折叠、缓存会话、置顶/归档会话)与演示 `.claude` 配置。

import ACPKit
import Foundation
import OMLog
import WorkbenchKit

/// 演示数据预置。
public enum DemoSeed {
    /// 预置全部演示数据:`.claude` 配置总是刷新;工作台状态仅在文件不存在时写入(保留用户在演示里的操作)。
    /// - Parameters:
    ///   - paths: 沙盒路径
    ///   - infos: 演示项目
    ///   - now: 基准时间
    public static func seed(paths: DemoPaths, infos: [DemoProjectInfo], now: Date = Date()) throws {
        try DemoClaudeHome.write(home: paths.home, atlasPath: paths.project("atlas-web").path)
        if !FileManager.default.fileExists(atPath: paths.workbenchFile.path) {
            try WorkbenchStore(fileURL: paths.workbenchFile).save(workbenchState(infos: infos, now: now))
            Log.app.info("演示工作台状态已预置", ["file": paths.workbenchFile.path, "projects": "\(infos.count)"])
        }
    }

    /// 构造预置的工作台状态。
    /// - Parameters:
    ///   - infos: 演示项目
    ///   - now: 基准时间
    public static func workbenchState(infos: [DemoProjectInfo], now: Date = Date()) -> WorkbenchState {
        var state = WorkbenchState()
        state.layout.rightVisible = false
        for (index, info) in infos.enumerated() {
            var entry = ProjectEntry(url: URL(fileURLWithPath: info.path), now: now.addingTimeInterval(-Double(index) * 3_600))
            entry.addedAt = now.addingTimeInterval(-Double(index + 3) * 86_400)
            entry.pinned = info.name == "atlas-web"
            entry.collapsed = info.name == "empty-project"
            let history = DemoHistory.sessions(forProject: info.name)
            entry.sessions = history.map { CachedSession(sessionId: $0.id, title: $0.title, updatedAt: $0.updatedAt(now: now)) }
            entry.pinnedSessions = history.filter(\.pinned).map(\.id)
            entry.archivedSessions = history.filter(\.archived).map(\.id)
            state.projects.append(entry)
        }
        state.selectedProjectID = state.projects.first?.id
        return state
    }
}
