// @author ixxxxoooo
// 退出计划模式的后续:「继续规划」中断收尾为 cancelled;「清空上下文并实施计划」换一个全新的 `claude`
// 进程(新 CLI 会话),在同一个 ACP 回合里把批准的计划作为首条消息继续(与 Node 适配器的 clear-context 重启一致)。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    /// 计划模式在 ACP 上的计划 ID(与翻译层 `plan_update` 一致)。
    private static let planModeId = "plan-mode"

    /// 结果是否为「ExitPlanMode 中断」产生的诊断:`result_type=user` 且 `stop_reason=tool_use`。
    static func isExitPlanInterruption(_ message: JSONValue) -> Bool {
        guard message["is_error"]?.boolValue == true else { return false }
        let candidates: [String]
        if message["subtype"]?.stringValue == "success" {
            candidates = [message["result"]?.stringValue ?? ""]
        } else {
            candidates = (message["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        guard let diagnostic = candidates.first(where: { $0.hasPrefix("[ede_diagnostic]") }) else { return false }
        func has(_ token: String) -> Bool {
            diagnostic.split(whereSeparator: { $0.isWhitespace }).contains { $0 == Substring(token) }
        }
        return has("result_type=user") && has("stop_reason=tool_use")
    }

    /// 处理 ExitPlanMode 中断结果。
    /// - Returns: 是否已接管该结果(调用方应直接返回)
    func handleExitPlanInterruption(_ message: JSONValue) async -> Bool {
        guard let pending = pendingExitPlan else { return false }
        pendingExitPlan = nil
        guard pending.interrupted || pending.contextReset != nil, Self.isExitPlanInterruption(message) else { return false }
        if let reset = pending.contextReset {
            await continuePlanInFreshContext(plan: reset.plan, mode: reset.mode)
        } else {
            // 「继续规划」:中断是用户有意为之,回合以 cancelled 收尾
            await closeUnfinishedToolCalls(cancelled: true)
            await settleOrDefer(makeOutcome("cancelled"))
        }
        return true
    }

    /// 清空上下文并实施计划:结束当前 `claude`,拉起全新进程并把计划作为首条消息交给它,沿用同一个 ACP 回合。
    /// - Parameters:
    ///   - plan: 批准的计划正文
    ///   - mode: 实施时的权限模式
    func continuePlanInFreshContext(plan: String, mode: String) async {
        guard !closed, let turn = active, !turn.settled else {
            log.warning("清空上下文被忽略:没有进行中的回合")
            return
        }
        let started = ContinuousClock.now
        let keepModel = models.currentModelId
        let keepAgent = currentAgent
        let keepEffort = effortPinned
        let keepFast = fastEnabled
        await closeUnfinishedToolCalls(cancelled: false)
        toolFields.clear()
        liveTasks.removeAll()
        hookedTools.removeAll()
        turn.deferredSettle = nil
        owedTrailingIdles = 0
        lastSessionState = nil

        mcpAuthTask?.cancel()
        mcpAuthTask = nil
        let oldQuery = query
        query = nil
        await oldQuery?.close()
        var creation = SessionCreation()
        creation.permissionMode = mode
        creation.reuseSessionId = UUID().uuidString.lowercased()
        do {
            try await boot(creation)
        } catch {
            log.error("清空上下文重启失败", error: error)
            await failActive(error)
            closed = true
            await onEnded(id)
            return
        }
        startMcpAuthentication()
        await restoreSettings(model: keepModel, agent: keepAgent, effort: keepEffort, fast: keepFast)
        usage.lastAssistantTotal = nil
        await send(["sessionUpdate": "current_mode_update", "currentModeId": .string(currentMode)])
        await send(["sessionUpdate": "config_option_update", "configOptions": .array(configOptions)])
        if caps.plan {
            await send(["sessionUpdate": "plan_update", "plan": ["type": "markdown", "planId": .string(Self.planModeId), "content": .string(plan)]])
        }
        await query?.sendUser(content: [["type": "text", "text": .string("Implement the following plan:\n\n\(plan)")]], uuid: turn.promptUuid, human: true)
        log.info("已清空上下文并继续实施计划", ["mode": currentMode, "ms": "\(OMLogger.milliseconds(since: started))"])
    }

    /// 新进程起来后恢复旧会话里用户选定的模型、Agent、强度与 Fast(失败只记录,不阻断实施)。
    private func restoreSettings(model: String, agent: String, effort: String?, fast: Bool) async {
        var pending: [(String, JSONValue)] = []
        if model != models.currentModelId { pending.append((ModelCatalog.configId, .string(model))) }
        if agent != currentAgent { pending.append((AgentOptions.configId, .string(agent))) }
        if let effort, effort != effortPinned { pending.append((EffortOptions.configId, .string(effort))) }
        for (configId, value) in pending {
            do { _ = try await setConfigOption(configId: configId, value: value) } catch {
                log.warning("清空上下文后恢复配置失败", ["config": configId, "error": error.localizedDescription])
            }
        }
        if fast != fastEnabled {
            do { try await applyFastMode(fast) } catch {
                log.warning("清空上下文后恢复 Fast 失败", ["error": error.localizedDescription])
            }
        }
    }
}
