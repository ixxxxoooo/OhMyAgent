// @author ixxxxoooo
// 会话存档的写入:消息粒度合并(流式片段在内存拼接,消息完整后才落一行)、缓冲写盘、全量同步的临时文件与原子替换。

import ACPKit
import Foundation

/// 单个会话的写入状态。
struct ArchiveWriter {
    /// 会话工作目录
    var cwd: String?
    /// 合并中的流式片段(原始载荷模板 + 已拼接文本)
    var pending: (update: JSONValue, text: String)?
    /// 待写盘的行
    var buffer = Data()
    /// 已安排延迟写盘
    var writeScheduled = false
    /// 是否处于全量同步(写临时文件)
    var syncing = false
}

extension SessionArchive {
    /// 处理一条更新:瞬时状态丢弃;同一消息的文本片段合并;其他更新先结束合并中的片段再追加。
    func recordNow(_ key: SessionArchiveKey, cwd: String?, update: JSONValue) {
        guard !purged.contains(key.sessionId), let kind = update["sessionUpdate"]?.stringValue, !SessionArchiveFormat.transientKinds.contains(kind) else { return }
        var writer = writers[key] ?? ArchiveWriter(cwd: cwd)
        if writer.cwd == nil { writer.cwd = cwd }
        if let text = Self.mergeableText(update) {
            if let pending = writer.pending, Self.sameMessage(pending.update, update) {
                writer.pending = (pending.update, pending.text + text)
                writers[key] = writer
                return
            }
            finalizePending(&writer)
            writer.pending = (update, text)
            writers[key] = writer
            if !writer.buffer.isEmpty { scheduleWrite(key) }
            return
        }
        finalizePending(&writer)
        append(SessionArchiveFormat.update(update), to: &writer, key: key)
        writers[key] = writer
        if writer.buffer.count >= bufferLimit { writeBuffer(key) } else { scheduleWrite(key) }
    }

    /// 回合结束:片段落盘 + 写同步时间 + 立即写盘。
    func flushTurn(_ key: SessionArchiveKey) {
        guard var writer = writers[key] else { return }
        finalizePending(&writer)
        if !writer.syncing, !writer.buffer.isEmpty || exists(key) {
            append(SessionArchiveFormat.meta(syncedAt: Date()), to: &writer, key: key)
        }
        writers[key] = writer
        writeBuffer(key)
    }

    /// 把缓冲写入目标文件(正式存档或同步临时文件);文件不存在时先写头信息。
    func writeBuffer(_ key: SessionArchiveKey) {
        guard var writer = writers[key] else { return }
        writer.writeScheduled = false
        defer { writers[key] = writer }
        guard !writer.buffer.isEmpty else { return }
        let url = writer.syncing ? syncURL(key) : fileURL(key)
        do {
            try appendData(writer.buffer, to: url, header: SessionArchiveFormat.header(key, cwd: writer.cwd, createdAt: Date()))
            writer.buffer.removeAll(keepingCapacity: true)
        } catch {
            log.error("会话存档写入失败", error: error, ["session": String(key.sessionId.prefix(8)), "bytes": "\(writer.buffer.count)"])
            writer.buffer.removeAll()
        }
    }

    /// 开始全量同步:丢弃未落盘的片段与缓冲(它们会随引擎回放重新到达),清掉残留的临时文件。
    func beginSyncNow(_ key: SessionArchiveKey, cwd: String?) {
        var writer = writers[key] ?? ArchiveWriter(cwd: cwd)
        if let cwd { writer.cwd = cwd }
        writer.pending = nil
        writer.buffer.removeAll()
        writer.syncing = true
        writers[key] = writer
        try? FileManager.default.removeItem(at: syncURL(key))
    }

    /// 结束全量同步并决定是否替换现有存档。
    func endSyncNow(_ key: SessionArchiveKey, success: Bool) -> SessionArchiveSyncOutcome {
        guard var writer = writers[key], writer.syncing else { return .failed }
        let temp = syncURL(key), target = fileURL(key)
        let fm = FileManager.default
        guard success else {
            writer.pending = nil
            writer.buffer.removeAll()
            writer.syncing = false
            writers[key] = writer
            try? fm.removeItem(at: temp)
            return .failed
        }
        finalizePending(&writer)
        if !writer.buffer.isEmpty { append(SessionArchiveFormat.meta(syncedAt: Date()), to: &writer, key: key) }
        writers[key] = writer
        writeBuffer(key)
        writers[key]?.syncing = false
        let fresh = (try? Data(contentsOf: temp)).flatMap(SessionArchiveFormat.parse)
        guard let fresh, !fresh.updates.isEmpty else {
            try? fm.removeItem(at: temp)
            return .empty
        }
        let current = (try? Data(contentsOf: target)).flatMap(SessionArchiveFormat.parse)
        do {
            if let current, current.updates == fresh.updates {
                try? fm.removeItem(at: temp)
                try appendData(SessionArchiveFormat.line(SessionArchiveFormat.meta(syncedAt: Date())) ?? Data(), to: target, header: nil)
                return .unchanged
            }
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
                log.info("会话存档已替换", ["session": String(key.sessionId.prefix(8)), "updates": "\(fresh.updates.count)"])
                return .replaced
            }
            try fm.moveItem(at: temp, to: target)
            log.info("会话存档已建立", ["session": String(key.sessionId.prefix(8)), "updates": "\(fresh.updates.count)"])
            return .created
        } catch {
            log.error("会话存档同步落盘失败", error: error, ["session": String(key.sessionId.prefix(8))])
            try? fm.removeItem(at: temp)
            return .failed
        }
    }

    /// 读取存档(先写出该会话的缓冲;合并中的片段属于未完成的消息,不读出)。
    func loadNow(_ key: SessionArchiveKey) -> ArchivedSession? {
        if writers[key]?.syncing == false { writeBuffer(key) }
        guard let data = try? Data(contentsOf: fileURL(key)), let archived = SessionArchiveFormat.parse(data), !archived.updates.isEmpty else { return nil }
        return archived
    }

    /// 删除存档与临时文件。
    func deleteNow(_ key: SessionArchiveKey) {
        writers[key] = nil
        let fm = FileManager.default
        for url in [fileURL(key), syncURL(key)] where fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { log.error("删除会话存档失败", error: error, ["session": String(key.sessionId.prefix(8))]) }
        }
    }

    // MARK: 辅助

    /// 合并中的片段写成一行完整消息。
    private func finalizePending(_ writer: inout ArchiveWriter) {
        guard let pending = writer.pending else { return }
        writer.pending = nil
        guard var object = pending.update.objectValue, var content = object["content"]?.objectValue else { return }
        content["text"] = .string(pending.text)
        object["content"] = .object(content)
        if let line = SessionArchiveFormat.line(SessionArchiveFormat.update(.object(object))) { writer.buffer.append(line) }
    }

    /// 追加一行;尚未建档时只有内容类更新才会开始建档(只有元数据的空会话不落盘)。
    private func append(_ record: JSONValue, to writer: inout ArchiveWriter, key: SessionArchiveKey) {
        let kind = record["u"]?["sessionUpdate"]?.stringValue
        let target = writer.syncing ? syncURL(key) : fileURL(key)
        let started = !writer.buffer.isEmpty || FileManager.default.fileExists(atPath: target.path)
        if !started, kind.map(SessionArchiveFormat.contentKinds.contains) != true { return }
        if let line = SessionArchiveFormat.line(record) { writer.buffer.append(line) }
    }

    /// 追加数据到文件;文件不存在且给出头信息时先建文件(权限 0600)并写头信息。
    private func appendData(_ data: Data, to url: URL, header: JSONValue?) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard let header, let headerLine = SessionArchiveFormat.line(header) else { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: headerLine, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// 可合并的纯文本片段:返回其文本;带 `_meta`(如通知)或非文本内容不合并。
    static func mergeableText(_ update: JSONValue) -> String? {
        guard let kind = update["sessionUpdate"]?.stringValue, SessionArchiveFormat.chunkKinds.contains(kind),
              update["_meta"] == nil, let content = update["content"], content["type"]?.stringValue == "text" else { return nil }
        return content["text"]?.stringValue
    }

    /// 两个片段是否属于同一条消息:类型相同,且消息 ID 相同;助手/思考片段都没有 ID 时视为连续的同一条,用户片段必须有 ID。
    static func sameMessage(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        let kind = lhs["sessionUpdate"]?.stringValue
        guard kind == rhs["sessionUpdate"]?.stringValue else { return false }
        let left = lhs["messageId"]?.stringValue, right = rhs["messageId"]?.stringValue
        if let left, let right { return left == right }
        return left == nil && right == nil && kind != "user_message_chunk"
    }
}
