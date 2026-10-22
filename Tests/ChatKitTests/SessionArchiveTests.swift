// @author ixxxxoooo
// 会话存档测试:往返、片段合并、空会话不建档、容错读取、同步替换/不变/失败、文件名安全、陈旧判定、删除。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

/// 建一个临时目录下的存档。
private func makeArchive() -> (SessionArchive, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-archive-\(UUID().uuidString)", isDirectory: true)
    return (SessionArchive(root: root, writeDelay: .milliseconds(10)), root)
}

private func chunk(_ kind: String, _ text: String, id: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["sessionUpdate": .string(kind), "content": ["type": "text", "text": .string(text)]]
    if let id { object["messageId"] = .string(id) }
    return .object(object)
}

private let key = SessionArchiveKey(agentId: "claude-code", sessionId: "6f1c1e0a-0000-4000-8000-000000000001")

@Suite("会话存档", .serialized)
struct SessionArchiveTests {
    @Test("流式片段合并为一条消息,工具调用原样保留,瞬时状态不落盘")
    func mergesChunks() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.record(key, cwd: "/tmp/p", update: chunk("user_message_chunk", "你好", id: "u1"))
        archive.record(key, cwd: "/tmp/p", update: chunk("agent_message_chunk", "好"))
        archive.record(key, cwd: "/tmp/p", update: chunk("agent_message_chunk", "的"))
        archive.record(key, cwd: "/tmp/p", update: ["sessionUpdate": "available_commands_update", "availableCommands": []])
        archive.record(key, cwd: "/tmp/p", update: ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "读取"])
        archive.record(key, cwd: "/tmp/p", update: chunk("agent_message_chunk", "完成"))
        archive.flush(key)
        let loaded = try #require(await archive.load(key))
        #expect(loaded.updates.count == 4)
        #expect(loaded.updates[1]["content"]?["text"]?.stringValue == "好的")
        #expect(loaded.updates[2]["sessionUpdate"]?.stringValue == "tool_call")
        #expect(loaded.updates[3]["content"]?["text"]?.stringValue == "完成")
        #expect(loaded.meta.cwd == "/tmp/p")
        #expect(loaded.meta.syncedAt != nil)
    }

    @Test("不同消息 ID 的片段不合并;没有 ID 的用户片段不合并")
    func keepsDistinctMessages() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "A", id: "m1"))
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "B", id: "m2"))
        archive.record(key, cwd: nil, update: chunk("user_message_chunk", "x"))
        archive.record(key, cwd: nil, update: chunk("user_message_chunk", "y"))
        archive.flush(key)
        let texts = await archive.load(key)?.updates.compactMap { $0["content"]?["text"]?.stringValue }
        #expect(texts == ["A", "B", "x", "y"])
    }

    @Test("只有元数据、没有任何消息的会话不建档")
    func emptySessionHasNoFile() async {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.record(key, cwd: nil, update: ["sessionUpdate": "session_info_update", "title": "空"])
        archive.flush(key)
        #expect(await archive.load(key) == nil)
        #expect(archive.exists(key) == false)
    }

    @Test("坏行与截断的末行被跳过,其余内容照常读出")
    func toleratesCorruption() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "保留", id: "m1"))
        archive.flush(key)
        _ = await archive.load(key)
        let handle = try FileHandle(forWritingTo: archive.fileURL(key))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"t\":\"u\",\"u\":{\"sessionUp".utf8))
        try handle.close()
        let loaded = try #require(await archive.load(key))
        #expect(loaded.updates.count == 1)
    }

    @Test("格式版本不符的存档视为不存在")
    func rejectsOtherSchema() throws {
        let data = Data("{\"t\":\"h\",\"schema\":999}\n{\"t\":\"u\",\"u\":{\"sessionUpdate\":\"plan\"}}\n".utf8)
        #expect(SessionArchiveFormat.parse(data) == nil)
    }

    @Test("全量同步:新建 → 内容相同不替换 → 内容变化原子替换 → 失败不动旧档")
    func syncOutcomes() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.beginSync(key, cwd: "/tmp/p")
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "一", id: "m1"))
        #expect(await archive.endSync(key, success: true) == .created)

        archive.beginSync(key, cwd: nil)
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "一", id: "m1"))
        #expect(await archive.endSync(key, success: true) == .unchanged)

        archive.beginSync(key, cwd: nil)
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "一", id: "m1"))
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "二", id: "m2"))
        #expect(await archive.endSync(key, success: true) == .replaced)
        #expect(await archive.load(key)?.updates.count == 2)

        archive.beginSync(key, cwd: nil)
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "残缺", id: "m9"))
        #expect(await archive.endSync(key, success: false) == .failed)
        #expect(await archive.load(key)?.updates.count == 2)
        #expect(FileManager.default.fileExists(atPath: archive.syncURL(key).path) == false)
    }

    @Test("同步期间不写临时文件(内容攒在内存),结束时一次落盘")
    func syncDefersWrites() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.beginSync(key, cwd: "/tmp/p")
        for index in 0..<50 { archive.record(key, cwd: nil, update: chunk("tool_call", "t\(index)")) }
        try await Task.sleep(for: .milliseconds(120))   // 远超 writeDelay(10ms):若在写盘,临时文件早已存在
        #expect(FileManager.default.fileExists(atPath: archive.syncURL(key).path) == false)
        #expect(await archive.endSync(key, success: true) == .created)
        #expect(await archive.load(key)?.updates.count == 50)
    }

    @Test("按字节比较更新行:相同判为相同,头信息/元数据行不影响;旧格式与不同内容退回解析")
    func sameUpdateLines() {
        func file(_ updates: [JSONValue], created: String, synced: String) -> Data {
            var data = SessionArchiveFormat.line(["t": "h", "schema": .int(SessionArchiveFormat.schema), "createdAt": .string(created)]) ?? Data()
            for update in updates { data.append(SessionArchiveFormat.line(SessionArchiveFormat.update(update)) ?? Data()) }
            data.append(SessionArchiveFormat.line(SessionArchiveFormat.meta(syncedAt: Date(timeIntervalSince1970: 0))) ?? Data())
            _ = synced
            return data
        }
        let a = [chunk("agent_message_chunk", "一", id: "m1"), chunk("agent_message_chunk", "二", id: "m2")]
        #expect(SessionArchiveFormat.sameUpdateLines(file(a, created: "x", synced: "1"), file(a, created: "y", synced: "2")))
        #expect(!SessionArchiveFormat.sameUpdateLines(file(a, created: "x", synced: "1"), file(Array(a.dropLast()), created: "x", synced: "1")))
        // 没有任何更新行 / 含无法识别的行:不能判定相同
        #expect(!SessionArchiveFormat.sameUpdateLines(Data(), Data()))
        let legacy = Data("{\"u\":{\"sessionUpdate\":\"plan\"},\"t\":\"u\"}\n".utf8)
        #expect(!SessionArchiveFormat.sameUpdateLines(legacy, legacy))
    }

    @Test("同步期间引擎没有返回内容:不建档")
    func syncEmpty() async {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.beginSync(key, cwd: nil)
        #expect(await archive.endSync(key, success: true) == .empty)
        #expect(archive.exists(key) == false)
    }

    @Test("同步完成后实时回合继续追加到正式存档")
    func liveAfterSync() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.beginSync(key, cwd: nil)
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "历史", id: "m1"))
        _ = await archive.endSync(key, success: true)
        archive.record(key, cwd: nil, update: chunk("user_message_chunk", "新问题", id: "u2"))
        archive.flush(key)
        #expect(await archive.load(key)?.updates.count == 2)
    }

    @Test("文件名安全:UUID 原样,含路径字符或过长的标识取哈希")
    func safeNames() {
        #expect(SessionArchiveFormat.safeName("6f1c1e0a-0000-4000-8000-000000000001") == "6f1c1e0a-0000-4000-8000-000000000001")
        let hashed = SessionArchiveFormat.safeName("../../etc/passwd")
        #expect(hashed.count == 64)
        #expect(!hashed.contains("/"))
        #expect(SessionArchiveFormat.safeName(".hidden").count == 64)
        #expect(SessionArchiveFormat.safeName(String(repeating: "a", count: 200)).count == 64)
    }

    @Test("陈旧判定:超出容差才算落后;未同步视为陈旧;引擎时间未知不算")
    func staleness() {
        let synced = Date(timeIntervalSince1970: 1000)
        #expect(SessionArchiveFormat.isStale(sourceUpdatedAt: synced.addingTimeInterval(4), syncedAt: synced) == false)
        #expect(SessionArchiveFormat.isStale(sourceUpdatedAt: synced.addingTimeInterval(6), syncedAt: synced) == true)
        #expect(SessionArchiveFormat.isStale(sourceUpdatedAt: nil, syncedAt: synced) == false)
        #expect(SessionArchiveFormat.isStale(sourceUpdatedAt: synced, syncedAt: nil) == true)
    }

    @Test("删除与清空")
    func deleteAndClear() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = SessionArchiveKey(agentId: "opencode", sessionId: "ses_1")
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "a", id: "m1"))
        archive.record(other, cwd: nil, update: chunk("agent_message_chunk", "b", id: "m1"))
        archive.flush(key)
        archive.flush(other)
        _ = await archive.load(other)
        #expect(archive.usage().files == 2)
        await archive.delete(key)
        #expect(archive.exists(key) == false)
        await archive.removeAll(agentId: "opencode")
        #expect(archive.usage().files == 0)
    }

    @Test("用户删除会话:各引擎下的存档都被删除,之后到达的更新被忽略")
    func purgeAcrossAgents() async {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = SessionArchiveKey(agentId: "opencode", sessionId: key.sessionId)
        archive.record(key, cwd: nil, update: chunk("agent_message_chunk", "a", id: "m1"))
        archive.record(other, cwd: nil, update: chunk("agent_message_chunk", "b", id: "m1"))
        archive.flush(key)
        archive.flush(other)
        _ = await archive.load(other)
        await archive.purge(sessionId: key.sessionId)
        #expect(archive.usage().files == 0)
        archive.record(key, cwd: nil, update: ["sessionUpdate": "tool_call", "toolCallId": "late"])
        archive.flush(key)
        #expect(await archive.load(key) == nil)
    }

    @Test("延迟写盘:不调 flush 也会在短延迟后落盘")
    func delayedWrite() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }
        archive.record(key, cwd: nil, update: ["sessionUpdate": "tool_call", "toolCallId": "t1"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(archive.exists(key))
    }
}
