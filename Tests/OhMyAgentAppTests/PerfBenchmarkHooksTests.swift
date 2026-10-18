// @author ixxxxoooo
// 性能基准计划测试:挑选会话的顺序、数量上限与过滤规则。

import Foundation
import Testing
import WorkbenchKit
@testable import OhMyAgentApp

@Suite("性能基准计划")
struct PerfBenchmarkHooksTests {
    private func project(_ name: String, sessions: [String], archived: [String] = [], deleted: [String] = [], chatArea: Bool = false) -> ProjectEntry {
        var entry = ProjectEntry(url: URL(fileURLWithPath: "/tmp/\(name)"))
        entry.sessions = sessions.map { CachedSession(sessionId: $0, title: "标题-\($0)", updatedAt: nil) }
        entry.archivedSessions = archived
        entry.deletedSessions = deleted
        entry.isChatArea = chatArea
        return entry
    }

    @Test("按项目与缓存顺序挑选,受数量上限约束")
    func ordering() {
        let projects = [project("a", sessions: ["a1", "a2"]), project("b", sessions: ["b1", "b2"])]
        let picked = BenchmarkPlan.pick(from: projects, count: 3)
        #expect(picked.map(\.sessionId) == ["a1", "a2", "b1"])
        #expect(picked.first?.title == "标题-a1")
    }

    @Test("跳过会话区、已归档、已删除与空 ID")
    func filtering() {
        let projects = [
            project("chat", sessions: ["c1"], chatArea: true),
            project("a", sessions: ["a1", "a2", "", "a3"], archived: ["a1"], deleted: ["a2"]),
        ]
        #expect(BenchmarkPlan.pick(from: projects, count: 10).map(\.sessionId) == ["a3"])
    }

    @Test("数量非正时为空")
    func nonPositive() {
        #expect(BenchmarkPlan.pick(from: [project("a", sessions: ["a1"])], count: 0).isEmpty)
        #expect(BenchmarkPlan.pick(from: [project("a", sessions: ["a1"])], count: -2).isEmpty)
    }
}
