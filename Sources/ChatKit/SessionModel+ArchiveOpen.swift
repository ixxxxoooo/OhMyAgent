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
    /// 每批最多占用主线程的时间
    private static let archiveBatchBudget: Duration = .milliseconds(8)

    /// 把存档内容渲染进时间线(调用方保证时间线已清空、`sessionId` 已指向该会话)。
    /// - Parameters:
    ///   - sessionId: 协议会话 ID
    ///   - keepTurns: 只回显最近的轮数(更早的折叠,点「显示更早」再完整回显);nil 表示完整回显
    /// - Returns: 渲染结果
    func renderArchive(_ sessionId: String, keepTurns: Int? = TimelineWindow.defaultTurns) async -> ArchiveRenderResult {
        guard let archive = Self.archive else { return .unavailable }
        let started = ContinuousClock.now
        let transcriptTurns = startTranscriptParse()
        archiveHidden = nil
        guard let archived = await archive.load(archiveKey(sessionId)) else { return .unavailable }
        let cut = ArchiveWindow.cut(archived.updates, keepTurns: keepTurns)
        // 只解码窗口内的更新(后台),被折叠的更早轮次不解码、不应用、不渲染
        let events = await Task.detached(priority: .userInitiated) {
            archived.updates[cut.start...].map { ClientEvent.sessionUpdate(sessionId: sessionId, update: SessionUpdate(json: $0)) }
        }.value
        let turns = await transcriptTurns?.value
        guard self.sessionId == sessionId else { return .superseded }
        timeline.beginReplay()
        timeline.replayResolveModel = { [weak self] raw in self?.resolveReplayModel(raw) ?? (raw, nil) }
        if let turns {
            // 折叠了更早的轮次时,记录里的回合只取与窗口对应的最近几个(按末尾对齐)
            timeline.replayTurns = cut.hiddenTurns > 0 ? Array(turns.suffix(cut.keptTurns)) : turns
            seedUsage(from: turns)
        }
        archiveHidden = cut.hiddenTurns > 0 ? (sessionId, cut.hiddenTurns) : nil
        var offset = 0
        while offset < events.count {
            // 按时间预算而不是固定条数切批:每批最多占用主线程约 8ms,批间让出,长会话回显时界面不冻结
            let batchStart = ContinuousClock.now
            var end = offset
            while end < events.count, end - offset < Self.archiveBatchSize, ContinuousClock.now - batchStart < Self.archiveBatchBudget {
                handle([events[end]])
                end += 1
            }
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
        log.info("会话存档已回显", ["target": String(sessionId.prefix(8)), "updates": "\(events.count)", "hiddenTurns": "\(cut.hiddenTurns)", "entries": "\(timeline.entries.count)",
                               "ms": "\(OMLogger.milliseconds(since: started))"])
        return .rendered(archived.meta)
    }

    /// 被折叠(未回显)的更早轮数;没有折叠为 0。只对当前会话有效。
    public var archiveHiddenTurns: Int {
        guard let hidden = archiveHidden, hidden.sessionId == sessionId else { return 0 }
        return hidden.turns
    }

    /// 是否可以完整回显被折叠的更早轮次(有折叠、空闲、存档可用)。运行中不允许:重新回显会替换时间线。
    public var canLoadEarlierArchive: Bool { archiveHiddenTurns > 0 && !isRunning && !isReplaying }

    /// 完整回显被折叠的更早轮次(重新从存档渲染全部)。
    /// - Returns: 重渲染后「原窗口第一条」对应的条目 ID(用于保持滚动位置);无法完成时为 nil
    @discardableResult
    public func loadEarlierArchive() async -> UUID? {
        guard canLoadEarlierArchive, let id = sessionId else { return nil }
        let oldCount = timeline.entries.count
        let span = log.span("展开存档更早轮次", warnMs: 500, ["hidden": "\(archiveHiddenTurns)"])
        timeline.reset()
        isReplaying = true
        let result = await renderArchive(id, keepTurns: nil)
        isReplaying = false
        span.end()
        guard case .rendered = result, self.sessionId == id else { return nil }
        let index = timeline.entries.count - oldCount
        return timeline.entries.indices.contains(index) ? timeline.entries[index].id : nil
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

    /// 是否可以从引擎重新同步当前会话(已连接、空闲、引擎支持 load、存档已启用)。
    public var canResyncFromEngine: Bool {
        Self.archive != nil && client != nil && phase == .ready && sessionId != nil && !isRunning && !isReplaying
            && archiveSyncing == nil && capabilities.loadSession
    }

    /// 从引擎重新同步当前会话:当前内容保持显示,后台静默 `session/load`,内容不同才替换。
    public func resyncFromEngine() {
        guard canResyncFromEngine, let sessionId, let client else { return }
        log.info("手动重新同步会话", ["target": String(sessionId.prefix(8))])
        silentSync(SessionSummary(sessionId: sessionId, cwd: workspace.path), client: client)
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
