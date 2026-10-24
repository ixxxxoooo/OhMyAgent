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

    @Test("重复点击同一历史会话:标签已关闭但会话仍保留时重开原槽位,不再每点一次多一个同名会话")
    func openHistoryDoesNotDuplicate() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.sessions[id]?.draft = "占位"
        model.openHistory(project: id, sessionId: "hist-dup", title: "遮挡问题")
        let first = model.conversations.count
        let tab = try #require(model.dock.allTabs.last)
        model.closeTab(tab.id)
        for _ in 0..<4 { model.openHistory(project: id, sessionId: "hist-dup", title: "遮挡问题") }
        #expect(model.conversations.count == first)
        #expect(model.conversations.values.filter { $0.sessionId == "hist-dup" }.count == 1)
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

    @Test("缓存归属:首次登记的引擎不被别的引擎承载的列表刷新改写")
    func cachedOwnerNotOverwrittenByOtherEngine() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = SessionSummary(sessionId: "0cf7fd62-uuid", cwd: id, title: "您是谁")
        model.cacheHistory([summary], agentID: "claude-code", for: id)
        model.cacheHistory([summary], agentID: "opencode", for: id)
        #expect(model.cachedAgentID(ofSession: "0cf7fd62-uuid", in: id) == "claude-code")
        // 新会话没有登记过时,取这次刷新的引擎
        model.cacheHistory([SessionSummary(sessionId: "ses_new", cwd: id, title: "新")], agentID: "opencode", for: id)
        #expect(model.cachedAgentID(ofSession: "ses_new", in: id) == "opencode")
        model.shutdownAll()
    }

    @Test("重启恢复:记录里的引擎与缓存归属冲突时,按缓存归属选择承载引擎并落盘纠正")
    func restoreUsesCachedOwner() throws {
        let (model, id, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.cacheHistory([SessionSummary(sessionId: "claude-uuid", cwd: id, title: "您是谁")], agentID: "claude-code", for: id)
        model.sessions[id]?.draft = "占位"
        model.openHistory(project: id, sessionId: "claude-uuid", title: "您是谁")
        model.saveNow()
        model.shutdownAll()

        // 模拟旧数据:恢复记录被错误地写成 opencode
        let file = root.appendingPathComponent("state/workbench.json")
        var state = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var slots = try #require(state["chatSlots"] as? [[String: Any]])
        #expect(slots.first?["agentId"] as? String == "claude-code")
        for index in slots.indices { slots[index]["agentId"] = "opencode" }
        state["chatSlots"] = slots
        try JSONSerialization.data(withJSONObject: state).write(to: file)

        let requested = LockedBox<[String]>([])
        let reopened = WorkbenchModel(store: WorkbenchStore(fileURL: file), autoConnect: false) { url in SessionModel(workspace: url) }
        reopened.makeAgentSession = { url, agent in
            requested.value.append(agent)
            return SessionModel(workspace: url)
        }
        reopened.select(project: id)
        #expect(requested.value.last == "claude-code")
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

/// 测试用的简单线程安全盒子。
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
