// @author ixxxxoooo
// 会话存档接线测试(脚本化 Agent):实时回合落盘(含客户端补记的用户消息)、打开历史会话时回放同步建档。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("会话存档接线", .serialized)
struct SessionArchiveFlowTests {
    /// 换上临时存档,返回存档与清理闭包。
    private func useTempArchive() -> (SessionArchive, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-archive-\(UUID().uuidString)", isDirectory: true)
        let archive = SessionArchive(root: root, writeDelay: .milliseconds(10))
        SessionModel.archive = archive
        return (archive, {
            SessionModel.archive = nil
            try? FileManager.default.removeItem(at: root)
        })
    }

    /// 轮询存档直到满足条件(写盘是异步的)。
    private func pollArchive(_ archive: SessionArchive, _ key: SessionArchiveKey, _ condition: (ArchivedSession) -> Bool) async -> ArchivedSession? {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let loaded = await archive.load(key), condition(loaded) { return loaded }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("实时回合:用户消息与助手回复都写入存档")
    func liveTurnIsArchived() async throws {
        let (archive, cleanup) = useTempArchive()
        defer { cleanup() }
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        defer { model.shutdown() }
        let sessionId = try #require(model.sessionId)
        model.send("存档里的问题")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        let key = model.archiveKey(sessionId)
        let loaded = await pollArchive(archive, key) { $0.updates.contains { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" } }
        #expect(loaded != nil)
        let user = loaded?.updates.first { $0["sessionUpdate"]?.stringValue == "user_message_chunk" }
        #expect(user?["content"]?["text"]?.stringValue == "存档里的问题")
        #expect(loaded?.meta.syncedAt != nil)
    }

    /// 发一轮消息、等存档落盘,再分叉出新会话(让「打开第一个会话」成为切换)。
    private func archivedThenForked(_ model: SessionModel, _ archive: SessionArchive) async throws -> String {
        let first = try #require(model.sessionId)
        model.send("存档里的问题")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        #expect(await pollArchive(archive, model.archiveKey(first)) { $0.updates.contains { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" } } != nil)
        model.forkCurrentSession()
        #expect(await SessionModelTests.wait { model.sessionId != first && model.sessionId != nil })
        return first
    }

    @Test("存档命中:打开会话直接回显存档内容(不经引擎回放),之后仍可继续对话")
    func openUsesArchive() async throws {
        let (archive, cleanup) = useTempArchive()
        defer { cleanup() }
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        defer { model.shutdown() }
        let first = try await archivedThenForked(model, archive)
        model.openSession(SessionSummary(sessionId: first, cwd: ws.path, updatedAt: "2000-01-01T00:00:00Z"))
        #expect(await SessionModelTests.wait { !model.isReplaying && model.sessionId == first && model.archiveSyncing == nil })
        #expect(model.timeline.entries.contains { $0.kind == .user && $0.text.contains("存档里的问题") })
        // 引擎回放的内容是「历史问题 / 历史回答」:没有出现说明没走 session/load
        #expect(!model.timeline.entries.contains { $0.text.contains("历史回答") })
        let assistants = model.timeline.entries.filter { $0.kind == .assistant }.count
        model.send("继续")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.filter { $0.kind == .assistant }.count > assistants })
    }

    @Test("存档落后于引擎:先回显存档,再静默同步并替换为引擎内容")
    func staleArchiveIsResynced() async throws {
        let (archive, cleanup) = useTempArchive()
        defer { cleanup() }
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        defer { model.shutdown() }
        let first = try await archivedThenForked(model, archive)
        model.openSession(SessionSummary(sessionId: first, cwd: ws.path, updatedAt: "2099-01-01T00:00:00Z"))
        #expect(await SessionModelTests.wait { model.archiveSyncing == nil && model.timeline.entries.contains { $0.text.contains("历史回答") } })
        // 静默同步期间回放事件不进时间线:引擎内容只出现一次
        #expect(model.timeline.entries.filter { $0.kind == .assistant && $0.text.contains("历史回答") }.count == 1)
        #expect(!model.timeline.entries.contains { $0.text.contains("存档里的问题") })
    }

    @Test("打开历史会话:回放内容同步为存档")
    func replayIsSynced() async throws {
        let (archive, cleanup) = useTempArchive()
        defer { cleanup() }
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        defer { model.shutdown() }
        let first = try #require(model.sessionId)
        model.send("第一条")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        #expect(await SessionModelTests.wait { model.history.contains { $0.sessionId == first } })
        // 去掉实时回合留下的存档,验证回放会重新建档
        await archive.delete(model.archiveKey(first))
        model.forkCurrentSession()
        #expect(await SessionModelTests.wait { model.sessionId != first && model.sessionId != nil })
        let summary = try #require(model.history.first { $0.sessionId == first })
        model.openSession(summary)
        #expect(await SessionModelTests.wait { !model.isReplaying && model.sessionId == first })
        let loaded = await pollArchive(archive, model.archiveKey(first)) { _ in true }
        #expect(loaded?.updates.contains { $0["sessionUpdate"]?.stringValue == "user_message_chunk" } == true)
        #expect(FileManager.default.fileExists(atPath: archive.syncURL(model.archiveKey(first)).path) == false)
    }
}
