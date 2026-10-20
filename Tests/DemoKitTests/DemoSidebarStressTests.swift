// @author ixxxxoooo
// 项目栏压力数据测试:规格解析、幂等追加、置顶/归档分布。

import Foundation
import Testing
import WorkbenchKit
@testable import DemoKit

@Suite("项目栏压力数据")
struct DemoSidebarStressTests {
    private func makePaths() throws -> DemoPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        return DemoPaths(root: root)
    }

    @Test("环境变量解析:缺省关闭,项目数与会话数被夹到上限")
    func specParsing() {
        #expect(DemoSidebarStress.spec(environment: [:]) == nil)
        #expect(DemoSidebarStress.spec(environment: ["OMA_DEMO_SIDEBAR_PROJECTS": "0"]) == nil)
        #expect(DemoSidebarStress.spec(environment: ["OMA_DEMO_SIDEBAR_PROJECTS": "abc"]) == nil)
        #expect(DemoSidebarStress.spec(environment: ["OMA_DEMO_SIDEBAR_PROJECTS": "50"]) == .init(projects: 50, sessionsEach: 40))
        let clamped = DemoSidebarStress.spec(environment: ["OMA_DEMO_SIDEBAR_PROJECTS": "9999", "OMA_DEMO_SIDEBAR_SESSIONS": "99999"])
        #expect(clamped?.projects == DemoSidebarStress.maxProjects)
        #expect(clamped?.sessionsEach == DemoSidebarStress.maxSessions)
    }

    @Test("追加合成项目:数量、目录、会话数与置顶归档分布;重复应用不叠加")
    func applyIsIdempotent() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var state = WorkbenchState()
        let spec = DemoSidebarStress.Spec(projects: 5, sessionsEach: 20)
        try DemoSidebarStress.apply(to: &state, spec: spec, paths: paths)
        try DemoSidebarStress.apply(to: &state, spec: spec, paths: paths)
        #expect(state.projects.count == 5)
        #expect(state.projects.map(\.name) == (0..<5).map(DemoSidebarStress.projectName))
        for project in state.projects {
            #expect(project.sessions.count == 20)
            #expect(project.pinnedSessions.count == 1)
            #expect(project.archivedSessions.count == 3)
            #expect(FileManager.default.fileExists(atPath: project.id))
            #expect(Set(project.sessions.map(\.sessionId)).count == 20)
        }
    }

    @Test("不影响已有的非合成项目")
    func keepsOtherProjects() throws {
        let paths = try makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var state = WorkbenchState()
        let other = paths.projects.appendingPathComponent("atlas-web", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        state.projects = [ProjectEntry(url: other)]
        try DemoSidebarStress.apply(to: &state, spec: .init(projects: 3, sessionsEach: 5), paths: paths)
        #expect(state.projects.count == 4)
        try DemoSidebarStress.apply(to: &state, spec: .init(projects: 2, sessionsEach: 5), paths: paths)
        #expect(state.projects.count == 3)
        #expect(state.projects.first?.name == "atlas-web")
    }
}
