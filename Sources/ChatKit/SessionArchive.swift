// @author ixxxxoooo
// 会话存档:把每个会话的 `session/update` 流保存在本地,打开会话时直接从本地回显,不必等引擎。
// 存档是派生数据(引擎仍是事实来源),但会比引擎自身的清理(如 Claude Code 的 cleanupPeriodDays)保留得更久。

import ACPKit
import Foundation
import OMLog

/// 会话存档(actor)。写入经单一有序队列,保证落盘顺序与事件到达顺序一致。
public actor SessionArchive {
    /// 应用共用的存档:`Application Support/OhMyAgent[-Dev]/session-archive`(演示模式随主目录重定向进沙盒)
    public static let shared = SessionArchive(root: AppEnv.supportDirectory.appendingPathComponent("session-archive", isDirectory: true))

    /// 有序队列里的命令。
    enum Command: Sendable {
        case record(SessionArchiveKey, cwd: String?, update: JSONValue)
        case flush(SessionArchiveKey)
        case writeBuffer(SessionArchiveKey)
        case beginSync(SessionArchiveKey, cwd: String?)
        case endSync(SessionArchiveKey, success: Bool, reply: CheckedContinuation<SessionArchiveSyncOutcome, Never>)
        case load(SessionArchiveKey, reply: CheckedContinuation<ArchivedSession?, Never>)
        case delete(SessionArchiveKey, reply: CheckedContinuation<Void, Never>)
    }

    /// 存档根目录
    public nonisolated let root: URL
    private nonisolated let inbox: AsyncStream<Command>.Continuation
    var writers: [SessionArchiveKey: ArchiveWriter] = [:]
    let log = Log.session.with(["part": "archive"])
    /// 缓冲超过该字节数立即写盘;否则在 `writeDelay` 后写盘
    let bufferLimit = 64 * 1024
    let writeDelay: Duration

    /// 创建存档。
    /// - Parameters:
    ///   - root: 存档根目录
    ///   - writeDelay: 缓冲延迟写盘时间(测试可调短)
    public init(root: URL, writeDelay: Duration = .seconds(2)) {
        self.root = root
        self.writeDelay = writeDelay
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        inbox = continuation
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.apply(command)
            }
        }
    }

    deinit { inbox.finish() }

    // MARK: 对外接口(非隔离,可在任意线程同步调用;实际执行按调用顺序排队)

    /// 记录一条原始 `session/update`。
    /// - Parameters:
    ///   - key: 存档键
    ///   - cwd: 会话工作目录(建档时写入头信息)
    ///   - update: 原始更新载荷
    public nonisolated func record(_ key: SessionArchiveKey, cwd: String?, update: JSONValue) {
        inbox.yield(.record(key, cwd: cwd, update: update))
    }

    /// 回合结束:合并中的片段落盘、写同步时间、写盘。
    /// - Parameter key: 存档键
    public nonisolated func flush(_ key: SessionArchiveKey) {
        inbox.yield(.flush(key))
    }

    /// 开始全量同步(`session/load` 前调用):此后该会话的更新写入临时文件。
    /// - Parameters:
    ///   - key: 存档键
    ///   - cwd: 会话工作目录
    public nonisolated func beginSync(_ key: SessionArchiveKey, cwd: String?) {
        inbox.yield(.beginSync(key, cwd: cwd))
    }

    /// 结束全量同步:成功时与现有存档比较,有变化才原子替换;失败时丢弃临时文件。
    /// - Parameters:
    ///   - key: 存档键
    ///   - success: 引擎是否成功完成加载
    /// - Returns: 同步结果
    public nonisolated func endSync(_ key: SessionArchiveKey, success: Bool) async -> SessionArchiveSyncOutcome {
        await withCheckedContinuation { reply in inbox.yield(.endSync(key, success: success, reply: reply)) }
    }

    /// 读取存档(先把该会话已缓冲的内容写盘)。
    /// - Parameter key: 存档键
    /// - Returns: 存档;不存在、版本不符或没有内容时为 nil
    public nonisolated func load(_ key: SessionArchiveKey) async -> ArchivedSession? {
        await withCheckedContinuation { reply in inbox.yield(.load(key, reply: reply)) }
    }

    /// 删除存档(连同未完成的同步临时文件)。
    /// - Parameter key: 存档键
    public nonisolated func delete(_ key: SessionArchiveKey) async {
        await withCheckedContinuation { reply in inbox.yield(.delete(key, reply: reply)) }
    }

    /// 存档文件是否存在(只看文件,不读内容)。
    /// - Parameter key: 存档键
    public nonisolated func exists(_ key: SessionArchiveKey) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key).path)
    }

    /// 存档文件路径。
    /// - Parameter key: 存档键
    public nonisolated func fileURL(_ key: SessionArchiveKey) -> URL {
        root.appendingPathComponent(SessionArchiveFormat.safeName(key.agentId), isDirectory: true)
            .appendingPathComponent(SessionArchiveFormat.safeName(key.sessionId) + ".jsonl")
    }

    /// 同步临时文件路径。
    nonisolated func syncURL(_ key: SessionArchiveKey) -> URL {
        fileURL(key).appendingPathExtension("sync")
    }

    /// 占用统计。
    /// - Parameter agentId: 只统计该引擎;nil 统计全部
    /// - Returns: 文件数与总字节数
    public nonisolated func usage(agentId: String? = nil) -> (files: Int, bytes: Int64) {
        let base = agentId.map { root.appendingPathComponent(SessionArchiveFormat.safeName($0), isDirectory: true) } ?? root
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files, bytes)
    }

    /// 清空存档(内存中的写入状态一并丢弃)。
    /// - Parameter agentId: 只清该引擎;nil 清空全部
    public func removeAll(agentId: String? = nil) {
        writers = writers.filter { key, _ in agentId != nil && key.agentId != agentId }
        let target = agentId.map { root.appendingPathComponent(SessionArchiveFormat.safeName($0), isDirectory: true) } ?? root
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            log.info("会话存档已清空", ["agent": agentId ?? "*"])
        } catch {
            log.error("清空会话存档失败", error: error, ["agent": agentId ?? "*"])
        }
    }

    // MARK: 执行

    private func apply(_ command: Command) {
        switch command {
        case .record(let key, let cwd, let update): recordNow(key, cwd: cwd, update: update)
        case .flush(let key): flushTurn(key)
        case .writeBuffer(let key): writeBuffer(key)
        case .beginSync(let key, let cwd): beginSyncNow(key, cwd: cwd)
        case .endSync(let key, let success, let reply): reply.resume(returning: endSyncNow(key, success: success))
        case .load(let key, let reply): reply.resume(returning: loadNow(key))
        case .delete(let key, let reply): deleteNow(key); reply.resume()
        }
    }

    /// 安排一次延迟写盘(同一会话只排一次)。
    func scheduleWrite(_ key: SessionArchiveKey) {
        guard writers[key]?.writeScheduled == false else { return }
        writers[key]?.writeScheduled = true
        let delay = writeDelay
        let inbox = inbox
        Task {
            try? await Task.sleep(for: delay)
            inbox.yield(.writeBuffer(key))
        }
    }
}
