// @author ixxxxoooo
// 会话创建时间恒定性、物理文件时间解析与自愈测试。

import ACPKit
import ChatKit
import Foundation
import Testing
@testable import WorkbenchKit

@MainActor
@Suite("会话创建时间与排序稳定性")
struct SessionOrderTests {
    private func makeModel() throws -> (WorkbenchModel, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-order-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let model = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        let id = try #require(model.openProject(dir))
        return (model, id, root)
    }

    @Test("CachedSession 优先以 createdAt 作为 stableKey")
    func stableKeyPriority() {
        let session = CachedSession(
            sessionId: "s1",
            title: "测试",
            updatedAt: "2026-06-01T00:00:00Z",
            createdAt: "2026-01-01T00:00:00Z",
            firstSeenAt: "2026-03-01T00:00:00Z"
        )
        let parsed = WorkbenchModel.parseDate("2026-01-01T00:00:00Z")
        #expect(session.stableKey == parsed)
    }

    @Test("缺失 updatedAt 时按原始列表顺序获得单调递减时间戳,保证相对顺序稳定且不同键")
    func missingUpdatedAtPreservesOrder() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let summaries = [
            SessionSummary(sessionId: "s1", cwd: id, title: "第一条", updatedAt: nil),
            SessionSummary(sessionId: "s2", cwd: id, title: "第二条", updatedAt: nil),
            SessionSummary(sessionId: "s3", cwd: id, title: "第三条", updatedAt: nil)
        ]
        let baseTime = Date(timeIntervalSince1970: 1_800_000_000)
        model.cacheHistory(summaries, agentID: "antigravity", for: id, now: baseTime)

        let cached = try #require(model.projects.first?.sessions)
        #expect(cached.count == 3)
        #expect(cached[0].stableKey > cached[1].stableKey)
        #expect(cached[1].stableKey > cached[2].stableKey)
        model.shutdownAll()
    }

    @Test("已确立创建时间的会话在多次刷新或更新时保持创建时间不变")
    func createdAtNeverChangesOnUpdates() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let initial = [
            SessionSummary(sessionId: "s1", cwd: id, title: "会话", updatedAt: "2026-01-01T00:00:00Z")
        ]
        model.cacheHistory(initial, agentID: "claude-code", for: id, now: Date(timeIntervalSince1970: 1_800_000_000))

        let firstCached = try #require(model.projects.first?.sessions.first)
        let originalCreated = firstCached.createdAt

        // 该会话后续更新了 updatedAt 与标题
        let updated = [
            SessionSummary(sessionId: "s1", cwd: id, title: "新标题", updatedAt: "2026-10-17T00:00:00Z")
        ]
        model.cacheHistory(updated, agentID: "claude-code", for: id, now: Date(timeIntervalSince1970: 1_850_000_000))

        let secondCached = try #require(model.projects.first?.sessions.first)
        #expect(secondCached.createdAt == originalCreated)
        #expect(secondCached.title == "新标题")
        model.shutdownAll()
    }

    @Test("点击历史会话:新标签走恢复模式,从点击起就以该会话 ID 标识,不先建空会话")
    func openHistoryUsesRestoreMode() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // 当前会话有内容(草稿非空)→ 必须新开标签承载历史会话
        model.sessions[id]?.draft = "写到一半"
        let before = model.conversations.count
        model.openHistory(project: id, sessionId: "hist-1", title: "旧会话")
        #expect(model.conversations.count == before + 1)
        let opened = try #require(model.sessions[id])
        #expect(opened.sessionId == "hist-1")
        #expect(opened.sessionTitle == "旧会话")
        #expect(opened.isReplaying)
        model.shutdownAll()
    }

    @Test("重启恢复:有内容的会话标签在原标签里恢复同一个会话")
    func chatSlotsRestoredAfterRelaunch() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.sessions[id]?.draft = "占位"
        model.openHistory(project: id, sessionId: "hist-2", title: "恢复我")
        model.saveNow()
        model.shutdownAll()

        let store = WorkbenchStore(fileURL: root.appendingPathComponent("state/workbench.json"))
        let reopened = WorkbenchModel(store: store, autoConnect: false) { url in
            let session = SessionModel(workspace: url)
            session.attention = AttentionCenter()
            return session
        }
        reopened.select(project: id)
        let restored = try #require(reopened.sessions[id])
        #expect(restored.sessionId == "hist-2")
        reopened.shutdownAll()
    }

    @Test("删除会话:清缓存/置顶/归档并写墓碑,列表刷新后不会回来")
    func forgetSessionKeepsTombstone() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = [SessionSummary(sessionId: "d1", cwd: id, title: "要删的", updatedAt: nil), SessionSummary(sessionId: "d2", cwd: id, title: "保留", updatedAt: nil)]
        model.cacheHistory(items, agentID: "claude-code", for: id)
        model.toggleSessionPin("d1", in: id)
        #expect(model.forgetSession("d1", in: id))
        let entry = try #require(model.projects.first)
        #expect(!entry.sessions.contains { $0.sessionId == "d1" })
        #expect(!entry.pinnedSessions.contains("d1"))
        model.cacheHistory(items, agentID: "claude-code", for: id)
        #expect(model.projects[0].sessions.map(\.sessionId) == ["d2"])
        model.shutdownAll()
    }
}
