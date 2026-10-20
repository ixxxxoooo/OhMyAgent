// @author ixxxxoooo
// 演示预置数据测试:工作台状态可被 WorkbenchStore 读回,演示 `.claude` 能被 ClaudeConfigKit 各 Store 读出。

import ACPKit
import ClaudeConfigKit
import Foundation
import Testing
import WorkbenchKit
@testable import DemoKit

@Suite("演示预置数据", .serialized)
struct DemoSeedTests {
    private static func sandbox() async throws -> (DemoPaths, [DemoProjectInfo]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-seed-\(UUID().uuidString)")
        let paths = DemoPaths(root: root)
        let environment = DemoEnvironment(paths: paths)
        return (paths, try await environment.prepare())
    }

    @Test("workbench.json:多项目、置顶项目、折叠项目、缓存会话、置顶与归档会话")
    func workbench() async throws {
        let (paths, infos) = try await Self.sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let state = try #require(WorkbenchStore(fileURL: paths.workbenchFile).load())
        #expect(state.projects.count == infos.count)
        #expect(state.projects.first { $0.name == "atlas-web" }?.pinned == true)
        #expect(state.projects.first { $0.name == "empty-project" }?.collapsed == true)
        // 默认启动项目是性能实验室的多标签项目
        #expect(state.selectedProjectID == state.projects.first { $0.name == "perf-multitab" }?.id)
        for project in state.projects {
            let perf = project.name.hasPrefix("perf-")
            #expect(perf ? project.sessions.count >= 6 : (8...12).contains(project.sessions.count))
            #expect(!project.pinnedSessions.isEmpty)
            #expect(perf || !project.archivedSessions.isEmpty)
            #expect(project.pinnedSessions.allSatisfy { id in project.sessions.contains { $0.sessionId == id } })
        }
    }

    @Test("perf-multitab 预置 dock:4 个会话标签 + 文件/对比/历史/blame,会话可恢复")
    func multiTabDock() async throws {
        let (paths, _) = try await Self.sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let state = try #require(WorkbenchStore(fileURL: paths.workbenchFile).load())
        let dock = try #require(state.dock)
        let kinds = dock.allTabs.map(\.kind)
        #expect(dock.allTabs.count >= 12)
        #expect(kinds.contains { if case .diff = $0 { return true } else { return false } })
        #expect(kinds.contains { if case .history = $0 { return true } else { return false } })
        #expect(kinds.contains { if case .blame = $0 { return true } else { return false } })
        let slots = try #require(state.chatSlots)
        #expect(slots.count == 4)
        for slot in slots {
            #expect(DemoHistory.session(id: slot.sessionId) != nil)
            #expect(kinds.contains(.chat(projectID: slot.projectID, slot: slot.slot)))
        }
        // 所有文件标签的路径都真实存在(否则启动时会被清掉)
        for case .file(let path) in kinds { #expect(FileManager.default.fileExists(atPath: path), "\(path)") }
    }

    @Test("OMA_DEMO_PROJECT 覆盖启动项目(导览固定 atlas-web),且不预置多标签 dock")
    func focusOverride() async throws {
        let (paths, infos) = try await Self.sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try DemoSeed.seed(paths: paths, infos: infos, environment: ["OMA_DEMO_PROJECT": "atlas-web"])
        let state = try #require(WorkbenchStore(fileURL: paths.workbenchFile).load())
        #expect(state.selectedProjectID == paths.project("atlas-web").path)
        let fresh = DemoSeed.workbenchState(infos: infos, focus: "atlas-web")
        #expect(fresh.dock == nil && fresh.chatSlots == nil)
    }

    @Test("已存在的工作台状态不会被再次预置覆盖")
    func keepsExistingState() async throws {
        let (paths, infos) = try await Self.sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = WorkbenchStore(fileURL: paths.workbenchFile)
        var state = try #require(store.load())
        state.projects.removeLast()
        try store.save(state)
        try DemoSeed.seed(paths: paths, infos: infos)
        #expect(store.load()?.projects.count == infos.count - 1)
    }

    @Test("演示 .claude:记忆、Skills、命令、Subagent、MCP、Hooks、插件、权限")
    func claudeHome() async throws {
        let (paths, _) = try await Self.sandbox()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let atlas = paths.project("atlas-web")
        let claude = ClaudePaths(home: paths.home, workspace: atlas)
        #expect(MemoryStore(paths: claude).list().contains { $0.exists && $0.url.lastPathComponent == "CLAUDE.md" })
        let plugins = PluginStore(paths: claude)
        let installed = plugins.installed()
        #expect(Set(installed.map(\.name)) == ["demo-toolkit", "docs-writer"])
        #expect(installed.first { $0.name == "demo-toolkit" }?.isEnabled == true)
        #expect(installed.first { $0.name == "docs-writer" }?.isEnabled == false)
        #expect(plugins.marketplaces().count == 1)
        let servers = try MCPStore(paths: claude).list()
        #expect(Set(servers.map(\.config.name)).isSuperset(of: ["github", "filesystem", "sqlite", "atlas-db"]))
        let hooks = try HooksStore(paths: claude).list()
        #expect(hooks.count >= 3)
        #expect(SkillStore(paths: claude).list().count >= 3)
        // 演示配置不得包含任何疑似密钥
        let settings = try String(contentsOf: claude.userSettings, encoding: .utf8)
        #expect(!settings.lowercased().contains("token") && !settings.contains("sk-"))
    }
}
