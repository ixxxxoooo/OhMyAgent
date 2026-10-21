// @author ixxxxoooo
// 回合管理:提示排队、取消(含强制收尾)、引导(steer)与回合收尾的公共逻辑。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    // MARK: 提示

    /// 处理一次 `session/prompt`:排队、发给 `claude`,等回合收尾。
    /// - Parameter blocks: ACP 内容块
    /// - Returns: 响应体(`stopReason`/`usage`/`_meta`)
    /// - Throws: 回合失败(鉴权失效、模型错误、进程退出)
    func prompt(_ blocks: [JSONValue]) async throws -> JSONValue {
        try requireOpen()
        // 首条消息等 MCP 连接落定,避免第 2 轮提示缓存整段失效
        await awaitMcpReady()
        try requireOpen()
        if !turns.contains(where: { !$0.settled }) {
            cancelled = false
            cancelledPrompts.removeAll()
        }
        if autoFallbackWarnPending { await publishAutoFallbackWarning() }
        let content = PromptConverter.convert(blocks)
        guard !content.isEmpty else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "提示内容为空") }
        let uuid = UUID().uuidString.lowercased()
        let firstText = blocks.first.flatMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil } ?? ""
        let command = firstText.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let isLocalOnly = firstText.hasPrefix("/") && SlashCommands.localOnly.contains(command)
        noteTitlePrompt(blocks)
        let (stream, sink) = AsyncThrowingStream<PromptOutcome, Error>.makeStream()
        let turn = SessionTurn(promptUuid: uuid, isLocalOnly: isLocalOnly, sink: sink)
        turns.append(turn)
        log.info("提示入队", ["prompt": uuid, "queued": "\(turns.filter { !$0.settled }.count)"])
        await query?.sendUser(content: content, uuid: uuid, human: true)
        for try await outcome in stream { return outcome.response }
        throw JSONRPCError(code: JSONRPCError.internalError, message: "会话已结束")
    }

    // MARK: 取消

    /// 处理 `session/cancel`:标记取消、向 `claude` 发中断,并在宽限期后强制收尾。
    func cancel() async {
        guard !closed, let query else { return }
        let unsettled = turns.filter { !$0.settled }
        if !unsettled.isEmpty {
            cancelled = true
            for turn in unsettled {
                cancelledPrompts.insert(turn.promptUuid)
                cancelledPrompts.formUnion(turn.steeredUuids)
            }
        }
        pendingExitPlan = nil
        await cancelOpenPermissionRequests()
        armForceSettle()
        do {
            try await query.control("interrupt")
        } catch {
            log.warning("中断请求失败", ["error": error.localizedDescription])
        }
    }

    /// 取消后若 `claude` 迟迟不回结果,到期强制把回合收尾为 `cancelled`。
    private func armForceSettle() {
        forceSettleTask?.cancel()
        guard turns.contains(where: { !$0.settled }) else { return }
        let grace = config.cancelGraceSeconds
        forceSettleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            await self?.forceSettleAfterCancel()
        }
    }

    private func forceSettleAfterCancel() async {
        guard cancelled else { return }
        let pending = turns.filter { !$0.settled }
        guard !pending.isEmpty else { return }
        log.warning("取消后宽限期已到,强制收尾", ["turns": "\(pending.count)"])
        await closeUnfinishedToolCalls(cancelled: true)
        let outcome = makeOutcome("cancelled")
        for turn in pending { turn.resolve(outcome) }
        turns.removeAll()
        active = nil
        emittedAssistantText = false
    }

    // MARK: 引导

    /// 处理 `_session/steering`:把消息注入运行中的回合。
    /// - Parameters:
    ///   - blocks: 内容块
    ///   - promptRequired: 没有运行中的回合时是否让调用方改走 `session/prompt`
    /// - Returns: `{outcome: injected|promptRequired|startedNewTurn}`
    func steer(_ blocks: [JSONValue], promptRequired: Bool) async throws -> JSONValue {
        try requireOpen()
        guard let inflight = turns.first(where: { !$0.settled }) else {
            if promptRequired { return ["outcome": "promptRequired", "reason": "noRunningTurn"] }
            Task { [weak self] in
                do { _ = try await self?.prompt(blocks) } catch { self?.log.error("引导启动的新回合失败", error: error) }
            }
            return ["outcome": "startedNewTurn"]
        }
        let content = PromptConverter.convert(blocks)
        let uuid = UUID().uuidString.lowercased()
        inflight.steeredEchoes.insert(uuid)
        inflight.steeredUuids.insert(uuid)
        if let deferred = inflight.deferredSettle {
            inflight.steeredSettle = deferred
            inflight.deferredSettle = nil
        }
        await query?.sendUser(content: content, uuid: uuid, priority: openPermissionRequests > 0 ? "later" : "now", human: true)
        return ["outcome": "injected"]
    }

    // MARK: 收尾

    /// 当前回合是否在等后台子代理。
    func turnAwaitingSubagents(_ turn: SessionTurn) -> Bool {
        turn.spawnedTaskIds.contains { liveTasks[$0]?.isSubagent == true }
    }

    /// 交付回合结果并推进队列。
    func deliver(_ turn: SessionTurn, _ outcome: PromptOutcome) {
        guard !turn.settled else { return }
        turn.resolve(outcome)
        if active === turn { active = nil }
        turns.removeAll { $0.settled }
        emittedAssistantText = false
        if !turns.contains(where: { !$0.settled }) { forceSettleTask?.cancel() }
    }

    /// 收尾当前活动回合。
    func settleActive(_ outcome: PromptOutcome) async {
        guard let turn = active, !turn.settled else { return }
        if outcome.stopReason == "end_turn" { await closeUnfinishedToolCalls(cancelled: false) }
        toolFields.clear()
        deliver(turn, outcome)
    }

    /// 引导中先暂存、等子代理时先挂起,否则立即收尾。
    func settleOrDefer(_ outcome: PromptOutcome) async {
        guard let turn = active, !turn.settled else { return }
        if turn.isSteering {
            turn.steeredSettle = outcome
            return
        }
        if turnAwaitingSubagents(turn) {
            turn.deferredSettle = outcome
            return
        }
        await settleActive(outcome)
    }

    /// 子代理都结束后交付暂存的结果。
    func settleDeferredIfDrained() async {
        guard let turn = active, let outcome = turn.deferredSettle, !turnAwaitingSubagents(turn) else { return }
        await settleActive(outcome)
    }

    /// 用结果里的 `user_message_uuid(s)` 把结果对应到队列里的回合。
    func ensureActive(uuids: [String]) async {
        if let current = active {
            guard let deferred = current.deferredSettle else { return }
            await settleActive(deferred)
        }
        let pending = turns.filter { !$0.settled }
        active = uuids.lazy.compactMap { id in pending.first { $0.promptUuid == id } }.first ?? pending.first
        if active != nil { resetTurnScratch() }
    }

    /// 回合激活时清空逐回合的用量与失败暂存(与 Node 版 `resetTurnScratch` 一致):
    /// `prompt` 响应里的 `usage` 与 `_meta.quota` 只反映本回合花费。
    func resetTurnScratch() {
        usage.lastAssistantTotal = nil
        usage.lastAssistantUsage = nil
        usage.lastAssistantModel = nil
        usage.accumulated = TokenTally()
        usage.accumulatedByModel = [:]
        lastAssistantError = nil
        lastAssistantWasUsageLimit = false
        lastRefusalExplanation = nil
    }

    /// 以错误结束当前回合。
    func failActive(_ error: Error) async {
        guard let turn = active ?? turns.first(where: { !$0.settled }), !turn.settled else { return }
        await closeUnfinishedToolCalls(cancelled: false)
        turn.reject(error)
        if active === turn { active = nil }
        turns.removeAll { $0.settled }
        emittedAssistantText = false
    }

    /// 回合结束仍未返回结果的工具调用:标记为未完成。
    /// - Parameter cancelled: 是否因取消而结束
    func closeUnfinishedToolCalls(cancelled: Bool) async {
        let backgroundTools = Set(liveTasks.values.compactMap(\.parentToolUseId))
        for toolCallId in translator.unfinishedToolCallIds where !backgroundTools.contains(toolCallId) {
            let report = translator.renderer.unfinished(toolCallId: toolCallId, ran: !cancelled, cancelled: cancelled)
            var update = report
            if let toolUse = translator.toolUse(id: toolCallId), let exit = translator.renderer.terminalExit(toolUse), var object = report.objectValue {
                var meta = object["_meta"]?.objectValue ?? [:]
                for (key, value) in exit.objectValue ?? [:] { meta[key] = value }
                object["_meta"] = .object(meta)
                update = .object(object)
            }
            hookedTools[toolCallId] = nil
            translator.forgetToolCall(toolCallId)
            await send(update)
        }
    }
}
