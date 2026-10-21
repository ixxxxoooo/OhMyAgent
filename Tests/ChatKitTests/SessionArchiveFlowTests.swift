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
