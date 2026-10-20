// @author ixxxxoooo
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
    public static func seed(paths: DemoPaths, infos: [DemoProjectInfo], now: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let focus = environment["OMA_DEMO_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
        try DemoClaudeHome.write(home: paths.home, atlasPath: paths.project("atlas-web").path)
        try DemoCanvas.write(home: paths.home, projectPath: paths.project("atlas-web").path, now: now)
        let stress = DemoSidebarStress.spec(environment: environment)
        if !FileManager.default.fileExists(atPath: paths.workbenchFile.path) {
            var state = workbenchState(infos: infos, now: now, focus: focus)
            if let stress { try DemoSidebarStress.apply(to: &state, spec: stress, paths: paths, now: now) }
            try WorkbenchStore(fileURL: paths.workbenchFile).save(state)
            Log.app.info("演示工作台状态已预置", ["file": paths.workbenchFile.path, "projects": "\(infos.count)"])
        } else if let focus {
            // 显式指定了启动项目(如导览脚本固定用 atlas-web):覆盖已落盘状态里的选中项目
            let store = WorkbenchStore(fileURL: paths.workbenchFile)
            if var state = store.load(), let target = infos.first(where: { $0.name == focus }), state.selectedProjectID != target.path {
                state.selectedProjectID = target.path
                try store.save(state)
            }
        }
        // 项目栏压力数据:对已落盘的状态也追加(幂等),便于不重置沙盒直接复测
        if let stress, FileManager.default.fileExists(atPath: paths.workbenchFile.path) {
            let store = WorkbenchStore(fileURL: paths.workbenchFile)
            if var state = store.load() {
                try DemoSidebarStress.apply(to: &state, spec: stress, paths: paths, now: now)
                try store.save(state)
            }
        }
    }

    /// 构造预置的工作台状态。
    /// - Parameters:
    ///   - infos: 演示项目
    ///   - now: 基准时间
    ///   - focus: 启动时选中的项目名;默认 `perf-multitab`(预置多标签),找不到时回退第一个项目
    public static func workbenchState(infos: [DemoProjectInfo], now: Date = Date(), focus: String? = nil) -> WorkbenchState {
        var state = WorkbenchState()
        state.layout.rightVisible = false
        // 性能实验室的会话标题带测试目的前缀,加宽左栏让标题尽量完整可读
        state.layout.leftWidth = min(340, PanelMetrics.leftRange.upperBound)
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
        let target = focus ?? defaultFocus
        let selected = state.projects.first { $0.name == target } ?? state.projects.first
        state.selectedProjectID = selected?.id
        // 选中多标签实验室时预置 dock(多个会话 + 源码/文档/CSV/配置/对比/历史/blame 标签),无需任何命令
        if let selected, selected.name == "perf-multitab" {
            let seeded = multiTabDock(projectID: selected.id)
            state.dock = seeded.dock
            state.chatSlots = seeded.slots
        }
        return state
    }

    /// 默认启动项目:性能实验室的多标签项目。
    public static let defaultFocus = "perf-multitab"

    /// 多标签实验室的预置布局:4 个会话标签 + 5 个文件标签 + 对比/历史/blame。
    /// - Parameter projectID: `perf-multitab` 的项目 ID(即目录绝对路径)
    /// - Returns: 停靠布局与会话恢复记录
    static func multiTabDock(projectID: String) -> (dock: DockLayout, slots: [ChatSlotRecord]) {
        var dock = DockLayout()
        let chats = DemoHistory.sessions(forProject: "perf-multitab").filter { ["perf-multitab-1", "perf-multitab-2", "perf-multitab-3", "perf-multitab-6"].contains($0.id.dropFirst("demo-".count)) }
        var slots: [ChatSlotRecord] = []
        var firstChat: UUID?
        for (index, item) in chats.sorted(by: { $0.id < $1.id }).enumerated() {
            let slot = "perf-\(index + 1)"
            let tab = dock.open(.chat(projectID: projectID, slot: slot), title: item.title)
            firstChat = firstChat ?? tab
            slots.append(ChatSlotRecord(projectID: projectID, slot: slot, sessionId: item.id, agentId: nil, title: item.title))
        }
        for relative in ["src/Engine.swift", "src/Router.swift", "docs/guide.md", "data/sales.csv", "config/app.json", "README.md"] {
            let tab = dock.open(.file(path: projectID + "/" + relative), title: (relative as NSString).lastPathComponent)
            dock.keepOpen(tab)
        }
        dock.keepOpen(dock.open(.diff(path: projectID + "/docs/guide.md"), title: "guide.md (改动)"))
        dock.keepOpen(dock.open(.history(projectID: projectID, path: nil), title: "提交历史"))
        dock.keepOpen(dock.open(.blame(path: projectID + "/src/Router.swift"), title: "Router.swift (blame)"))
        if let firstChat { dock.activate(firstChat) }
        return (dock, slots)
    }
}
