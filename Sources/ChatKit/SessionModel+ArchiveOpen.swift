// @author ixxxxoooo
// 打开会话时优先从本地存档回显:先把存档内容渲染进时间线,再在后台接回引擎;
// 引擎侧有更新(或引擎只能 load 才能接回)时做一次「静默同步」:回放事件不进时间线,只写存档,内容变化才重渲染。

import ACPKit
import Foundation
import OMLog

/// 存档回显的结果。
enum ArchiveRenderResult: Sendable {
    /// 已渲染,附带存档元数据(用于陈旧判定)
    case rendered(SessionArchiveMeta)
    /// 没有可用存档(不存在、版本不符、读取失败),应改走引擎回放
    case unavailable
    /// 渲染期间用户切到了别的会话,放弃
    case superseded
}

extension SessionModel {
    /// 每批喂给时间线的更新数:批与批之间让出主线程,长会话回显时界面不冻结
    private static let archiveBatchSize = 200

    /// 把存档内容渲染进时间线(调用方保证时间线已清空、`sessionId` 已指向该会话)。
    /// - Parameter sessionId: 协议会话 ID
    /// - Returns: 渲染结果
    func renderArchive(_ sessionId: String) async -> ArchiveRenderResult {
        guard let archive = Self.archive else { return .unavailable }
        let started = ContinuousClock.now
        let transcriptTurns = startTranscriptParse()
        guard let archived = await archive.load(archiveKey(sessionId)) else { return .unavailable }
        let events = await Task.detached(priority: .userInitiated) {
            archived.updates.map { ClientEvent.sessionUpdate(sessionId: sessionId, update: SessionUpdate(json: $0)) }
        }.value
        let turns = await transcriptTurns?.value
        guard self.sessionId == sessionId else { return .superseded }
        timeline.beginReplay()
        timeline.replayResolveModel = { [weak self] raw in self?.resolveReplayModel(raw) ?? (raw, nil) }
        if let turns {
            timeline.replayTurns = turns
            seedUsage(from: turns)
        }
        var offset = 0
        while offset < events.count {
            let end = min(offset + Self.archiveBatchSize, events.count)
            handle(Array(events[offset..<end]))
            offset = end
            if offset < events.count {
                await Task.yield()
                guard self.sessionId == sessionId else {
                    timeline.endReplay()
                    return .superseded
                }
            }
        }
        timeline.finishStreaming()
        timeline.endReplay()
        attachReplayedSummaries(turns: turns)
        isReplaying = false
        log.info("会话存档已回显", ["target": String(sessionId.prefix(8)), "updates": "\(events.count)", "entries": "\(timeline.entries.count)",
                               "ms": "\(OMLogger.milliseconds(since: started))"])
        return .rendered(archived.meta)
    }

    /// 打开会话(已重置状态):先回显存档,再接回引擎;存档不可用时退回引擎回放。
    /// - Parameters:
    ///   - summary: 会话摘要
    ///   - client: 当前连接
    func openFromArchive(_ summary: SessionSummary, client: ACPClient) {
        Task { [weak self] in
            guard let self else { return }
            await self.continueFromArchive(await self.renderArchive(summary.sessionId), summary: summary, client: client)
        }
    }

    /// 根据回显结果接回引擎或退回引擎回放。
    /// - Parameters:
    ///   - result: 回显结果
    ///   - summary: 会话摘要
    ///   - client: 当前连接
    func continueFromArchive(_ result: ArchiveRenderResult, summary: SessionSummary, client: ACPClient) async {
        switch result {
        case .rendered(let meta):
            attachArchived(summary, meta: meta, client: client)
        case .unavailable:
            guard sessionId == summary.sessionId else { return }
            timeline.reset()
            loadFromEngine(summary, client: client)
        case .superseded:
            break
        }
    }

    /// 存档已显示,接回引擎:存档落后或引擎只能 load 时静默同步;否则只 `session/resume`(不回放)。
    /// 接回完成前的发送进入排队。
    private func attachArchived(_ summary: SessionSummary, meta: SessionArchiveMeta, client: ACPClient) {
        let stale = SessionArchiveFormat.isStale(sourceUpdatedAt: SessionArchiveFormat.date(summary.updatedAt), syncedAt: meta.syncedAt)
        let target = String(summary.sessionId.prefix(8))
        if capabilities.loadSession, stale || !capabilities.canResume {
            log.info("存档回显后静默同步", ["target": target, "stale": stale ? "yes" : "no"])
            silentSync(summary, client: client)
        } else if capabilities.canResume {
            archiveSyncing = summary.sessionId
            let request = restoreRequest(summary)
            Task { [weak self] in
                do {
                    let setup = try await client.resumeSession(sessionId: request.id, cwd: request.cwd, mcpServers: request.servers, additionalDirectories: request.dirs, meta: request.meta)
                    if !setup.configOptions.isEmpty { self?.configOptions = setup.configOptions }
                } catch {
                    self?.reportArchivedAttachFailure(error, target: target)
                }
                self?.archiveSyncing = nil
                self?.flushQueuedPrompt()
            }
        } else {
            flushQueuedPrompt()
        }
    }

    /// 静默同步:`session/load` 接回引擎,回放事件不进时间线、只写存档临时文件;内容有变化才从存档重渲染。
    private func silentSync(_ summary: SessionSummary, client: ACPClient) {
        guard let archive = Self.archive else { return }
        let key = archiveKey(summary.sessionId)
        let request = restoreRequest(summary)
        archiveSyncing = summary.sessionId
        archive.beginSync(key, cwd: request.cwd)
        Task { [weak self] in
            var loaded = false
            do {
                let setup = try await client.loadSession(sessionId: request.id, cwd: request.cwd, mcpServers: request.servers, additionalDirectories: request.dirs, meta: request.meta)
                loaded = true
                if !setup.configOptions.isEmpty { self?.configOptions = setup.configOptions }
            } catch {
                self?.reportArchivedAttachFailure(error, target: String(summary.sessionId.prefix(8)))
            }
            // 屏障 + 排空:被屏蔽的回放事件都处理完,才能解除屏蔽
            await self?.awaitEventBarrier(client)
            await self?.drainEvents()
            let outcome = await archive.endSync(key, success: loaded)
            guard let self else { return }
            self.archiveSyncing = nil
            self.log.info("存档静默同步完成", ["target": String(summary.sessionId.prefix(8)), "outcome": "\(outcome)"])
            if outcome == .replaced, self.sessionId == summary.sessionId, !self.isRunning {
                self.timeline.reset()
                _ = await self.renderArchive(summary.sessionId)
            }
            self.flushQueuedPrompt()
        }
    }

    /// 存档已显示但接回引擎失败:内容保留(不当作空会话隐藏),只提示原因。
    private func reportArchivedAttachFailure(_ error: Error, target: String) {
        log.warning("存档回显后接回引擎失败", ["target": target, "error": "\(error)"])
        let reason = AgentErrorHints.classifyRestore(error) == .notFound
            ? String(localized: "引擎里已经没有这个会话(可能已被引擎清理),当前显示的是本地存档。")
            : AgentErrorHints.restoreMessage(for: error)
        timeline.appendNotice(reason, severity: "warning")
    }

    /// 恢复请求的参数(在主线程取快照)。
    private func restoreRequest(_ summary: SessionSummary) -> (id: String, cwd: String, servers: [MCPServerConfig], dirs: [String], meta: JSONValue?) {
        (summary.sessionId, workspace.path, mcpServers, additionalDirectories, effectiveMeta())
    }

    /// 静默同步期间要屏蔽的更新:会进时间线的内容;模式、配置、命令、用量等状态照常应用。
    /// - Parameter update: 协议更新
    static func isTranscriptContent(_ update: SessionUpdate) -> Bool {
        switch update {
        case .availableCommands, .currentMode, .configOptions, .sessionInfo, .usage: false
        default: true
        }
    }
}
