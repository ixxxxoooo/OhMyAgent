// @author ixxxxoooo
// `claude` 消息分发:系统事件、流式增量、完整消息、回合结果与会话状态机(idle 判定、子代理挂起、引导)。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    /// 由 Claude Code 自己发起(而非用户提示)的结果来源。
    static let autonomousOrigins: Set<String> = ["task-notification", "peer", "coordinator", "observer", "observer-activity"]

    /// 分发一条 CLI 消息。
    func handle(_ message: JSONValue) async {
        switch message["type"]?.stringValue {
        case "system": await handleSystem(message)
        case "result": await handleResult(message)
        case "stream_event": await handleStream(message)
        case "assistant", "user": await handleConversation(message)
        case "tool_progress": await handleToolProgress(message)
        case "rate_limit_event": await handleRateLimit(message)
        case "conversation_reset": await handleConversationReset()
        default: break
        }
    }

    // MARK: 系统事件

    private func handleSystem(_ message: JSONValue) async {
        switch message["subtype"]?.stringValue {
        case "init":
            await syncFastModeState(message["fast_mode_state"]?.stringValue, reason: message["fast_mode_disabled_reason"]?.stringValue)
            if let terminal = message["terminal_slash_commands"]?.arrayValue?.compactMap(\.stringValue), terminal != terminalCommands {
                terminalCommands = terminal
                await sendAvailableCommands()
            }
            for error in message["plugin_errors"]?.arrayValue ?? [] {
                log.error("插件加载失败", ["plugin": error["plugin"]?.stringValue ?? "-", "type": error["type"]?.stringValue ?? "-"])
            }
        case "status":
            await handleStatus(message)
        case "compact_boundary":
            await handleCompactBoundary(message)
        case "local_command_output":
            if let content = message["content"]?.stringValue, !content.isEmpty { await sendAssistantText(content, message: message) }
        case "session_state_changed":
            await handleSessionState(message["state"]?.stringValue ?? "")
        case "commands_changed":
            rawCommands = message["commands"]?.arrayValue ?? rawCommands
            await sendAvailableCommands()
        case "mirror_error":
            log.error("历史持久化失败", ["error": message["error"]?.stringValue ?? "-"])
        case "permission_denied":
            await handlePermissionDenied(message)
        case "informational":
            await handleInformational(message)
        case "task_started":
            registerLiveTask(message)
        case "task_notification":
            await endLiveTask(message["task_id"]?.stringValue, runId: message["run_id"]?.stringValue)
        case "task_updated":
            await handleTaskUpdated(message)
        case "api_retry":
            await handleApiRetry(message)
        case "model_refusal_fallback", "model_refusal_no_fallback":
            await handleRefusalFallback(message)
        default:
            break
        }
    }

    private func handleStatus(_ message: JSONValue) async {
        if message["status"]?.stringValue == "compacting" {
            await compactionStarted(id: message["uuid"]?.stringValue)
        } else if let result = message["compact_result"]?.stringValue {
            await compactionFinished(id: message["uuid"]?.stringValue, success: result == "success", facts: ["error": message["compact_error"]].compactMapValues { $0 })
        }
    }

    private func handleCompactBoundary(_ message: JSONValue) async {
        await compactionFinished(id: message["uuid"]?.stringValue, success: true, facts: Self.compactionFacts(message["compact_metadata"]))
        let used = message.at("compact_metadata", "post_tokens")?.intValue ?? 0
        usage.lastAssistantUsage = nil
        usage.lastAssistantTotal = used
        usage.contextUsedTokens = used
        await send(withUsageModel(["sessionUpdate": "usage_update", "used": .int(used), "size": .int(usage.contextWindowSize)]))
    }

    private func handlePermissionDenied(_ message: JSONValue) async {
        guard let toolUseId = message["tool_use_id"]?.stringValue else { return }
        hookedTools[toolUseId] = nil
        guard translator.emittedToolCalls.contains(toolUseId) else { return }
        let parent = message["agent_id"]?.stringValue.flatMap { liveTasks[$0]?.parentToolUseId }
        let update = translator.renderer.permissionDenied(
            toolCallId: toolUseId, toolName: message["tool_name"]?.stringValue ?? "", parentToolUseId: parent,
            decisionReasonType: message["decision_reason_type"]?.stringValue, decisionReason: message["decision_reason"]?.stringValue,
            message: message["message"]?.stringValue
        )
        await send(update)
    }

    private func handleInformational(_ message: JSONValue) async {
        let level = message["level"]?.stringValue ?? "info"
        let content = message["content"]?.stringValue ?? ""
        if caps.notices, level == "info" { return }
        let severity = level == "warning" ? "warning" : "info"
        let transcript = level == "info" ? content : "**\(Notices.sentenceCase(level)):** \(content)"
        let split = Notices.split(content, fallbackTitle: severity == "warning" ? "Claude reported a warning" : "Claude reported a notice")
        await send(Notices.updateOrTranscript(severity: severity, title: split.title, description: split.description, supports: caps.notices, transcript: transcript))
        if caps.notices, let turn = active ?? turns.first(where: { !$0.settled }) { turn.noticeTexts.append(Notices.normalize(content)) }
    }

    private func handleApiRetry(_ message: JSONValue) async {
        let attempt = message["attempt"]?.intValue ?? 1
        let maxRetries = message["max_retries"]?.intValue ?? attempt
        let status = message["error_status"]
        let reconnect = status == nil || status?.isNull == true
        if !reconnect, message["error"]?.stringValue == "authentication_failed" { return }
        func seconds(_ milliseconds: Int) -> String { "\(max(1, Int((Double(milliseconds) / 1000).rounded())))s" }
        var detail = ""
        if let waited = message.at("no_response", "waited_ms")?.intValue, let wait = message.at("no_response", "retry_wait_ms")?.intValue {
            detail = " No response after \(seconds(waited)); waiting up to \(seconds(wait))."
        }
        let title = reconnect
            ? "Reconnecting to Claude, attempt \(attempt) of \(maxRetries).\(detail)"
            : "Retrying Claude, attempt \(attempt) of \(maxRetries).\(detail)"
        await send(Notices.updateOrTranscript(severity: "warning", title: title, description: nil, supports: caps.notices))
    }

    // MARK: 后台任务

    private func registerLiveTask(_ message: JSONValue) {
        guard let taskId = message["task_id"]?.stringValue else { return }
        let subagent = message["subagent_type"]?.nonEmptyString != nil
        liveTasks[taskId] = LiveTask(
            taskType: message["task_type"]?.stringValue ?? "", parentToolUseId: message["tool_use_id"]?.nonEmptyString,
            isSubagent: subagent, description: message["description"]?.stringValue ?? "", runId: message["run_id"]?.stringValue
        )
        active?.spawnedTaskIds.insert(taskId)
    }

    private func handleTaskUpdated(_ message: JSONValue) async {
        guard let taskId = message["task_id"]?.stringValue else { return }
        switch message.at("patch", "status")?.stringValue {
        case "completed", "failed", "killed":
            await endLiveTask(taskId, runId: message["run_id"]?.stringValue)
        case "running", "pending":
            if var task = liveTasks[taskId] { task.runId = message["run_id"]?.stringValue ?? task.runId; liveTasks[taskId] = task }
        default:
            break
        }
    }

    /// 任务结束:从存活表移除。
    private func endLiveTask(_ taskId: String?, runId: String?) async {
        guard let taskId, let task = liveTasks[taskId] else { return }
        if let runId, let current = task.runId, runId != current { return }
        liveTasks[taskId] = nil
    }

    // MARK: 会话状态机

    private func handleSessionState(_ state: String) async {
        let previous = lastSessionState
        lastSessionState = state
        if state == "running", previous != "running", owedTrailingIdles > 0 {
            log.warning("进入 running,丢弃未兑现的尾随 idle", ["owed": "\(owedTrailingIdles)"])
            owedTrailingIdles = 0
        }
        guard state == "idle" else { return }
        if owedTrailingIdles == 0 { await closeUnfinishedToolCalls(cancelled: cancelled) }
        if cancelled, let turn = active, !turn.settled {
            if turn.isHeldOpen, owedTrailingIdles > 0 { owedTrailingIdles -= 1 }
            await settleActive(makeOutcome("cancelled"))
        } else if let turn = active, turn.isHeldOpen {
            if owedTrailingIdles > 0 { owedTrailingIdles -= 1 }
            await settleDeferredIfDrained()
        } else if let turn = active, let steered = turn.steeredSettle, !turn.isSteering {
            turn.steeredSettle = nil
            await settleActive(steered)
        } else if owedTrailingIdles > 0 {
            owedTrailingIdles -= 1
        } else if let turn = active, turn.isSteering {
            // 引导进行中的 idle:等引导消息的结果
        } else if !cancelled, let turn = active, !turn.settled {
            log.error("claude 回到 idle 却没有结果,回合以错误收尾", ["prompt": turn.promptUuid])
            await failActive(JSONRPCError(code: JSONRPCError.internalError, message: "Claude 在没有返回结果的情况下结束了本轮,请重试。"))
        }
        if !turns.contains(where: { !$0.settled }) { await publishTitleIfNeeded() }
    }

    // MARK: 结果

    /// 结果是否回应了一个仍在等待的提示(自治结果折叠了用户提示的情形)。
    private func answersPendingPrompt(_ uuids: [String]) -> Bool {
        uuids.contains { uuid in turns.contains { $0.promptUuid == uuid && !$0.settled && !$0.isHeldOpen } }
    }

    private func handleResult(_ message: JSONValue) async {
        let uuids = message["user_message_uuids"]?.arrayValue?.compactMap(\.stringValue) ?? message["user_message_uuid"]?.stringValue.map { [$0] } ?? []
        let originKind = message.at("origin", "kind")?.stringValue
        let autonomous = originKind.map { Self.autonomousOrigins.contains($0) } == true && !answersPendingPrompt(uuids)
        if !autonomous {
            await syncFastModeState(message["fast_mode_state"]?.stringValue, reason: message["fast_mode_disabled_reason"]?.stringValue)
            await ensureActive(uuids: uuids)
            consumeSteeredUuids(uuids)
        }
        if autonomous || !(active?.isSteering ?? false) || cancelled { owedTrailingIdles += 1 }
        _ = usage.recordResult(message, autonomous: autonomous)
        await publishResultUsage(message, originKind: originKind)

        if cancelled {
            if let turn = active, !turn.settled, !autonomous || (turn.isHeldOpen && Self.isAborted(message)) {
                await settleActive(makeOutcome("cancelled"))
            }
            return
        }
        if autonomous {
            if active?.isHeldOpen == true { await settleDeferredIfDrained() }
            return
        }
        await settleUserResult(message)
    }

    private static func isAborted(_ message: JSONValue) -> Bool {
        message["is_error"]?.boolValue == true && message["subtype"]?.stringValue == "error_during_execution"
    }

    /// 结果回应了引导消息:移出等待集合,全部回应后退出引导车道。
    private func consumeSteeredUuids(_ uuids: [String]) {
        guard !cancelled, let turn = active, turn.isSteering else { return }
        var answers = false
        for uuid in uuids {
            turn.steeredEchoes.remove(uuid)
            if turn.steeredUuids.contains(uuid) { answers = true }
        }
        if answers, turn.steeredEchoes.isEmpty { turn.steeredAwaitingResult = false }
    }

    private func publishResultUsage(_ message: JSONValue, originKind: String?) async {
        guard let used = usage.lastAssistantTotal else { return }
        var update: [String: JSONValue] = [
            "sessionUpdate": "usage_update", "used": .int(used), "size": .int(usage.contextWindowSize),
            "cost": ["amount": message["total_cost_usd"] ?? .null, "currency": "USD"],
        ]
        if let origin = message["origin"], !origin.isNull { update["_meta"] = ["_claude/origin": origin] }
        await send(withUsageModel(.object(update)))
    }

    /// 非自治结果:按子类型换算停止原因,出错则让回合以错误收尾。
    private func settleUserResult(_ message: JSONValue) async {
        let subtype = message["subtype"]?.stringValue ?? "success"
        let isError = message["is_error"]?.boolValue == true
        let resultText = message["result"]?.stringValue ?? ""
        let stopReasonField = message["stop_reason"]?.stringValue
        if isError, resultText.contains("Please run /login") {
            await failActive(JSONRPCError(code: -32000, message: "Authentication required"))
            return
        }
        if await handleExitPlanInterruption(message) { return }
        if stopReasonField == "refusal" {
            if let explanation = lastRefusalExplanation { await sendAssistantText(explanation, message: message) }
            await settleOrDefer(makeOutcome("refusal"))
            return
        }
        if isError, let turn = active, !turn.steeredEchoes.isEmpty {
            await settleOrDefer(makeOutcome("end_turn"))
            return
        }
        var stopReason = "end_turn"
        let errors = (message["errors"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        switch subtype {
        case "success":
            if stopReasonField == "max_tokens" {
                stopReason = "max_tokens"
            } else if isError {
                await failActive(providerError(resultText))
                return
            } else {
                await forwardResultText(message, text: resultText)
            }
        case "error_during_execution":
            if stopReasonField == "max_tokens" {
                stopReason = "max_tokens"
            } else if isError {
                await failActive(providerError(resultText.isEmpty ? errors : resultText))
                return
            }
        case "error_max_budget_usd", "error_max_turns", "error_max_structured_output_retries":
            if isError {
                await failActive(providerError(errors.isEmpty ? subtype : errors))
                return
            }
            stopReason = "max_turn_requests"
        default:
            break
        }
        await settleOrDefer(makeOutcome(stopReason))
    }

    /// 回合没有任何助手输出时,把 `result` 正文当作回复转发(如本地命令输出)。
    private func forwardResultText(_ message: JSONValue, text: String) async {
        guard !text.isEmpty else { return }
        let alreadyShown = active?.noticeTexts.contains(Notices.normalize(text)) == true
        let produced = (message.at("usage", "output_tokens")?.intValue ?? 0) > 0
        if active?.isLocalOnly == true || (!emittedAssistantText && !compactionDeliveredOutput && !produced && !alreadyShown) {
            await sendAssistantText(text, message: message)
        }
    }

    /// 模型/提供商错误:带原始细节的内部错误;限额与鉴权类给出可读提示。
    private func providerError(_ detail: String) -> JSONRPCError {
        let text = detail.isEmpty ? "Claude 请求失败" : detail
        var data: [String: JSONValue] = [:]
        if let kind = lastAssistantError { data["errorKind"] = .string(kind) }
        return JSONRPCError(code: JSONRPCError.internalError, message: text, data: data.isEmpty ? nil : .object(data))
    }

    // MARK: 流式与完整消息

    private func handleStream(_ message: JSONValue) async {
        guard let event = message["event"] else { return }
        let parent = message["parent_tool_use_id"]?.nonEmptyString
        let type = event["type"]?.stringValue
        if parent == nil, type == "message_start" || type == "message_delta" { await trackStreamUsage(event, type: type ?? "") }
        if type == "message_start" { translatorStreamMessageStart(event) }
        if cancelled { return }
        let updates = translator.translateStreamEvent(message)
        for update in updates {
            await emit(update, parent: parent)
        }
    }

    private func translatorStreamMessageStart(_ event: JSONValue) {
        // 翻译器内部维护 `currentStreamMessageId`,此处无需额外处理;保留钩子供测试观察
        _ = event
    }

    private func trackStreamUsage(_ event: JSONValue, type: String) async {
        if type == "message_start" {
            usage.lastAssistantUsage = TokenTally(usage: event.at("message", "usage"))
            if let model = event.at("message", "model")?.nonEmptyString, model != "<synthetic>" {
                usage.lastAssistantModel = model
                if !usage.contextWindowAuthoritative, usage.contextWindowSize == UsageTracker.defaultContextWindow,
                   let inferred = ModelCatalog.inferContextWindow(model) { usage.contextWindowSize = inferred }
            }
        } else {
            let delta = event["usage"]
            let previous = usage.lastAssistantUsage ?? TokenTally()
            usage.lastAssistantUsage = TokenTally(
                input: delta?["input_tokens"]?.intValue ?? previous.input, output: delta?["output_tokens"]?.intValue ?? previous.output,
                cacheRead: delta?["cache_read_input_tokens"]?.intValue ?? previous.cacheRead,
                cacheWrite: delta?["cache_creation_input_tokens"]?.intValue ?? previous.cacheWrite
            )
        }
        let total = usage.lastAssistantUsage?.total ?? 0
        guard total != usage.lastAssistantTotal else { return }
        usage.lastAssistantTotal = total
        usage.contextUsedTokens = total
        await send(withUsageModel(["sessionUpdate": "usage_update", "used": .int(total), "size": .int(usage.contextWindowSize)]))
    }

    private func handleConversation(_ message: JSONValue) async {
        let type = message["type"]?.stringValue ?? ""
        let parent = message["parent_tool_use_id"]?.nonEmptyString
        if let messageId = MessageTranslator.messageId(message), let uuid = message["uuid"]?.nonEmptyString { messageIdToUuid[messageId] = uuid }
        if type == "user", let uuid = message["uuid"]?.nonEmptyString {
            if let queued = turns.first(where: { $0.promptUuid == uuid && !$0.settled }) {
                await activate(queued)
                return
            }
            if message["isReplay"]?.boolValue == true {
                if let turn = active, turn.isSteering, turn.steeredEchoes.remove(uuid) != nil { turn.steeredAwaitingResult = true }
                return
            }
        }
        if cancelled { return }
        let inner = message["message"] ?? .null
        let model = inner["model"]?.stringValue
        if type == "assistant", parent == nil {
            if model != "<synthetic>" {
                let tally = TokenTally(usage: inner["usage"])
                usage.lastAssistantUsage = tally
                usage.lastAssistantTotal = tally.total
                usage.contextUsedTokens = tally.total
            }
            lastAssistantWasUsageLimit = Self.isSyntheticUsageLimit(inner)
            if let model, model != "<synthetic>" { usage.lastAssistantModel = model }
            if let error = message["error"]?.stringValue { lastAssistantError = error }
            if inner["stop_reason"]?.stringValue == "refusal" {
                lastRefusalExplanation = inner.at("stop_details", "explanation")?.stringValue ?? lastRefusalExplanation
            }
            if model == "<synthetic>", ReplayText.isSyntheticLogin(inner) {
                await failActive(JSONRPCError(code: -32000, message: "Authentication required"))
                return
            }
        }
        if let text = inner["content"]?.stringValue {
            if inner["role"]?.stringValue != "system", text.contains("<local-command-stdout>") {
                if let output = ReplayText.markerTagText(text, "local-command-stdout"), !output.isEmpty { await sendAssistantText(output, message: message) }
                return
            }
            if text.contains("<local-command-stderr>") {
                log.error("本地命令错误输出", ["text": String(text.prefix(300))])
                return
            }
            if type == "user" { return }
        }
        if type == "user", let blocks = inner["content"]?.arrayValue, blocks.count == 1, blocks[0]["type"]?.stringValue == "text" { return }
        if inner["role"]?.stringValue == "system" { return }
        let updates = translator.translateMessage(message, forwardSubagentText: forwardSubagentText)
        for update in updates { await emit(update, parent: parent) }
    }

    /// 用户消息回放确认了排队中的回合:让它成为活动回合,并收尾上一个。
    private func activate(_ queued: SessionTurn) async {
        if active !== queued {
            if let current = active {
                if cancelled {
                    owedTrailingIdles += 1
                    await settleActive(makeOutcome("cancelled"))
                } else if let deferred = current.deferredSettle {
                    await settleActive(deferred)
                } else if current.isSteering, let steered = current.steeredSettle {
                    owedTrailingIdles += 1
                    await settleActive(steered)
                } else {
                    await settleActive(makeOutcome("end_turn"))
                }
            }
            active = queued
        }
        resetTurnScratch()
        if cancelled, !cancelledPrompts.contains(queued.promptUuid) {
            cancelled = false
            cancelledPrompts.removeAll()
        }
    }

    static func isSyntheticUsageLimit(_ message: JSONValue) -> Bool {
        guard message["model"]?.stringValue == "<synthetic>" else { return false }
        let text = (message["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: " ").lowercased()
        return text.contains("usage limit") || text.contains("limit reached")
    }

    // MARK: 其他事件

    private func handleToolProgress(_ message: JSONValue) async {
        let toolUseId = message["tool_use_id"]?.stringValue
        let parent = message["parent_tool_use_id"]?.nonEmptyString
        let target = toolUseId.flatMap { translator.emittedToolCalls.contains($0) ? $0 : nil } ?? parent
        guard let target, translator.emittedToolCalls.contains(target) else { return }
        var subagentParent: String?
        if let parent, parent != target, liveTasks.values.contains(where: { $0.isSubagent && $0.parentToolUseId == parent }) { subagentParent = parent }
        let beat = translator.renderer.progress(
            toolCallId: target, toolName: message["tool_name"]?.stringValue, parentToolUseId: subagentParent,
            elapsedSeconds: message["elapsed_time_seconds"]?.doubleValue, subagentType: message["subagent_type"]?.stringValue, subagentRetry: message["subagent_retry"]
        )
        await send(beat)
    }

    private func handleRateLimit(_ message: JSONValue) async {
        guard let used = usage.lastAssistantTotal, let info = message["rate_limit_info"] else { return }
        await send(withUsageModel(["sessionUpdate": "usage_update", "used": .int(used), "size": .int(usage.contextWindowSize), "_meta": ["_claude/rateLimit": info]]))
    }

    private func handleConversationReset() async {
        await failActiveIfAny(reason: "对话已重置")
        liveTasks.removeAll()
        hookedTools.removeAll()
        translator.resetConversation()
        resetTitles()
        await send(["sessionUpdate": "plan", "entries": []])
    }

    private func failActiveIfAny(reason: String) async {
        await closeUnfinishedToolCalls(cancelled: false)
        log.info("对话重置", ["reason": reason])
    }

    // MARK: 发送辅助

    /// 发送一条更新,并登记首次出现的工具调用以便 PostToolUse 钩子回写最终 Diff。
    func emit(_ update: JSONValue, parent: String?) async {
        registerHook(for: update)
        if update["sessionUpdate"]?.stringValue == "agent_message_chunk", parent == nil {
            emittedAssistantText = true
            if let text = update.at("content", "text")?.stringValue { noteTitleAssistant(text) }
        }
        await send(update)
    }

    /// 以助手文本发送(本地命令输出、拒绝说明等)。
    func sendAssistantText(_ text: String, message: JSONValue) async {
        var update: [String: JSONValue] = ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)]]
        if let id = MessageTranslator.messageId(message) { update["messageId"] = .string(id) }
        emittedAssistantText = true
        await send(.object(update))
    }
}
