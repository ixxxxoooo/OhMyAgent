// @author ixxxxoooo
// 权限、征询与对话:`can_use_tool` → `session/request_permission`;AskUserQuestion / MCP 征询 / 拒绝回退 → `elicitation/create`。

import ACPKit
import Foundation

/// 等待实施的「退出计划模式」后续动作。
struct PendingExitPlan: Sendable {
    var toolUseId: String
    /// 用户选择「清空上下文并实施计划」时,为计划正文与目标模式
    var contextReset: (plan: String, mode: String)?
    /// 用户选择「继续规划」导致中断
    var interrupted = false
}

extension ClaudeSession {
    // MARK: 客户端请求(可被取消)

    /// 向客户端发请求,并登记为「待用户输入」:期间引导消息改用 `later` 优先级,取消时可整体撤销。
    func requestFromClient(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let key = UUID()
        let client = self.client
        let task = Task { try await client.request(method, params) }
        pendingClientRequests[key] = task
        openPermissionRequests += 1
        defer {
            pendingClientRequests[key] = nil
            openPermissionRequests -= 1
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 撤销所有等待用户的权限/征询请求(`session/cancel`)。
    func cancelOpenPermissionRequests() async {
        for task in pendingClientRequests.values { task.cancel() }
    }

    // MARK: can_use_tool

    func canUseTool(_ request: JSONValue, requestId: String) async -> JSONValue? {
        guard !closed, let toolName = request["tool_name"]?.stringValue else { return ["behavior": "deny", "message": "Session not found"] }
        let toolUseID = request["tool_use_id"]?.stringValue
        let input = request["input"] ?? .object([:])
        let agentID = request["agent_id"]?.nonEmptyString
        if cancelled, let toolUseID, liveStoppedWork(toolUseID) {
            log.info("拒绝已取消工作发起的工具调用", ["tool": toolName, "toolUseId": toolUseID])
            return ["behavior": "deny", "message": "The user cancelled this prompt."]
        }
        let parent = agentID.flatMap { liveTasks[$0]?.parentToolUseId }
        do {
            if toolName == "AskUserQuestion", caps.elicitationForm {
                await ensureToolCallEmitted(toolName, toolUseID, input, parent)
                return try await askUserQuestion(input, toolUseID: toolUseID)
            }
            return try await requestPermission(request, toolName: toolName, input: input, toolUseID: toolUseID, parent: parent)
        } catch is CancellationError {
            return nil
        } catch PermissionError.aborted {
            return nil
        } catch {
            log.warning("权限处理失败", ["tool": toolName, "error": error.localizedDescription])
            return ["behavior": "deny", "message": .string("Permission request failed: \(error.localizedDescription)")]
        }
    }

    /// 取消后由已停止的工作发起的工具调用(其回合已被取消)。
    private func liveStoppedWork(_ toolUseId: String) -> Bool {
        active == nil && turns.allSatisfy(\.settled)
    }

    private func ensureToolCallEmitted(_ name: String, _ id: String?, _ input: JSONValue, _ parent: String?, preview: [JSONValue]? = nil) async {
        guard let id else { return }
        if let update = translator.ensureEmitted(ToolUse(id: id, name: name, input: input), parent: parent, previewContent: preview) {
            registerHook(for: update)
            await send(update)
            if let preview { toolFields.pinContent(id, preview) }
        }
    }

    private func requestPermission(_ request: JSONValue, toolName: String, input: JSONValue, toolUseID: String?, parent: String?) async throws -> JSONValue {
        let suggestions = request["permission_suggestions"]
        let forcedAsk = request["matched_ask_rule"].map { !$0.isNull } == true || request["suppress_always_allow_rule"]?.boolValue == true
        let durable = DurableChangeSet.normalize(suggestions, forcedAsk: forcedAsk)
        let displayName = request["display_name"]?.nonEmptyString
        let defaultToNo = request["default_to_no"]?.boolValue == true
        let toolUse = ToolUse(id: toolUseID ?? UUID().uuidString, name: toolName, input: input)
        let options = PermissionOptionBuilder.build(PermissionOptionContext(
            toolName: toolName, displayName: displayName, input: input, cwd: spec.cwd, durableChangeSet: durable,
            allowPersistentOptions: !forcedAsk, defaultToNo: defaultToNo, availableModes: availableModes.map(\.id), prePlanMode: prePlanMode,
            contextUsedPercent: usage.contextWindowSize <= 0 || usage.contextUsedTokens <= 0 ? nil : max(0, min(100, Int((Double(usage.contextUsedTokens) / Double(usage.contextWindowSize) * 100).rounded())))
        ))
        let toolCall = permissionToolCall(toolUse, request: request, displayName: displayName, parent: parent)
        await ensureToolCallEmitted(toolName, toolUse.id, input, parent)
        let response = try await requestFromClient("session/request_permission", ["sessionId": .string(id), "toolCall": toolCall, "options": .array(options.map(\.json))])
        try Task.checkCancellation()
        var decision = try PermissionDecoder.decode(response: response, toolName: toolName, input: input, toolUseID: toolUseID, offered: options, durable: durable)
        decision.result = await applyAutoFallback(decision.result)
        if toolName == "ExitPlanMode", decision.isAllow,
           let mode = decision.updatedPermissions.first(where: { $0["type"]?.stringValue == "setMode" && $0["destination"]?.stringValue == "session" })?["mode"]?.stringValue {
            await send(["sessionUpdate": "current_mode_update", "currentModeId": .string(mode)])
            await updateConfigOption(PermissionModes.configId, .string(mode))
        }
        if toolName == "ExitPlanMode", let resetMode = decision.contextResetMode {
            let plan = input["plan"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !plan.isEmpty else { throw PermissionError.invalid("ExitPlanMode clear-context selection requires a plan") }
            pendingExitPlan = PendingExitPlan(toolUseId: toolUse.id, contextReset: (plan, effectiveMode(resetMode)))
        } else if toolName == "ExitPlanMode", decision.result["behavior"]?.stringValue == "deny", decision.result["interrupt"]?.boolValue == true {
            pendingExitPlan = PendingExitPlan(toolUseId: toolUse.id, contextReset: nil, interrupted: true)
        }
        return decision.result
    }

    /// 权限请求里的 `toolCall`(标题、内容、位置)。
    private func permissionToolCall(_ toolUse: ToolUse, request: JSONValue, displayName: String?, parent: String?) -> JSONValue {
        let facts = ToolCallRenderer.facts(toolUse.name, toolUse.input, cwd: spec.cwd)
        let host = toolUse.name == "SandboxNetworkAccess" ? PermissionOptionBuilder.plain(toolUse.input["host"]) : nil
        let isComputerUse = toolUse.name.hasPrefix("mcp__computer-use__")
        let subject = host ?? (isComputerUse ? displayName : nil)
        var extraLocations: [JSONValue] = []
        if let blocked = request["blocked_path"]?.nonEmptyString, !(facts.locations ?? []).contains(where: { $0["path"]?.stringValue == blocked }) {
            extraLocations = [["path": .string(blocked)]]
        }
        var fallback: [JSONValue]?
        if host != nil || isComputerUse {
            fallback = [["type": "content", "content": ["type": "text", "text": .string("```json\n\(toolUse.input.prettyText)\n```")]]]
        }
        var toolCall = translator.renderer.permissionToolCall(toolUse, cwd: spec.cwd, title: subject ?? facts.title, fallbackContent: fallback)
        if !extraLocations.isEmpty, var object = toolCall.objectValue {
            object["locations"] = .array((object["locations"]?.arrayValue ?? []) + extraLocations)
            toolCall = .object(object)
        }
        if parent != nil || toolUse.name.hasPrefix("mcp__") {
            var claude: [String: JSONValue] = ["toolName": .string(toolUse.name)]
            if let parent { claude["parentToolUseId"] = .string(parent) }
            if var object = toolCall.objectValue {
                object["_meta"] = ["claudeCode": .object(claude)]
                toolCall = .object(object)
            }
        }
        return toolCall
    }

    /// `auto` 对当前模型不可用时,把批准里的 `setMode auto` 改成回退模式并提示。
    private func applyAutoFallback(_ result: JSONValue) async -> JSONValue {
        guard result["behavior"]?.stringValue == "allow", effectiveMode("auto") != "auto",
              let updates = result["updatedPermissions"]?.arrayValue,
              updates.contains(where: { $0["type"]?.stringValue == "setMode" && $0["mode"]?.stringValue == "auto" }),
              var object = result.objectValue else { return result }
        object["updatedPermissions"] = .array(updates.map { update in
            guard update["type"]?.stringValue == "setMode", update["mode"]?.stringValue == "auto", var changed = update.objectValue else { return update }
            changed["mode"] = .string(PermissionModes.autoFallback)
            return .object(changed)
        })
        await publishAutoFallbackWarning()
        return .object(object)
    }

    // MARK: AskUserQuestion

    private func askUserQuestion(_ input: JSONValue, toolUseID: String?) async throws -> JSONValue {
        guard let questions = Elicitation.questions(from: input) else {
            return ["behavior": "deny", "message": "AskUserQuestion called with no valid questions."]
        }
        let params = Elicitation.createRequest(questions, sessionId: id, toolCallId: toolUseID)
        let response: JSONValue
        do {
            response = try await requestFromClient("elicitation/create", params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            log.error("无法向用户展示 AskUserQuestion", ["error": error.localizedDescription])
            return ["behavior": "deny", "message": "Could not present the question to the user."]
        }
        try Task.checkCancellation()
        guard let updated = Elicitation.applyAnswer(response, input: input, questions: questions) else { throw PermissionError.aborted }
        return ["behavior": "allow", "updatedInput": updated]
    }

    // MARK: MCP 征询与用户对话

    func elicitation(_ request: JSONValue) async -> JSONValue? {
        let isURL = request["mode"]?.stringValue == "url"
        guard isURL ? caps.elicitationURL : caps.elicitationForm, let params = Elicitation.mcpRequest(request, sessionId: id) else { return ["action": "decline"] }
        do {
            let response = try await requestFromClient("elicitation/create", params)
            try Task.checkCancellation()
            return Elicitation.mcpResult(response)
        } catch {
            if Task.isCancelled || error is CancellationError { return ["action": "cancel"] }
            log.error("转发 MCP 征询失败", ["error": error.localizedDescription])
            return ["action": "decline"]
        }
    }

    func userDialog(_ request: JSONValue) async -> JSONValue? {
        guard request["dialog_kind"]?.stringValue == Elicitation.refusalDialogKind || request["dialogKind"]?.stringValue == Elicitation.refusalDialogKind,
              let payload = request["payload"], let params = Elicitation.refusalRequest(payload: payload, sessionId: id) else { return ["behavior": "cancelled"] }
        do {
            let response = try await requestFromClient("elicitation/create", params)
            try Task.checkCancellation()
            return ["behavior": "completed", "result": .string(Elicitation.refusalResult(response))]
        } catch {
            if !Task.isCancelled { log.error("展示拒绝回退对话失败", ["error": error.localizedDescription]) }
            return ["behavior": "cancelled"]
        }
    }

    // MARK: 拒绝回退通知

    /// `model_refusal_fallback` / `model_refusal_no_fallback`。
    func handleRefusalFallback(_ message: JSONValue) async {
        if message["subtype"]?.stringValue == "model_refusal_no_fallback" {
            if lastRefusalExplanation == nil, message["refused_user_message_uuid"]?.isNull != true {
                lastRefusalExplanation = message["api_refusal_explanation"]?.nonEmptyString ?? message["content"]?.nonEmptyString
            }
            return
        }
        let local = message["scope"]?.stringValue == "local"
        let persistent = message["direction"]?.stringValue != "revert" && !local
        let original = message["original_model"]?.stringValue ?? "", fallback = message["fallback_model"]?.stringValue ?? ""
        let category = message["api_refusal_category"]?.nonEmptyString.map { " (\($0))" } ?? ""
        let outcome = persistent ? "The session will continue on \(fallback)."
            : local ? "Only that response came from \(fallback); the session stays on \(original)." : "The session stays on \(original)."
        let summary = "\(original) declined this request\(category); retried with \(fallback). \(outcome)"
        let explanation = message["api_refusal_explanation"]?.nonEmptyString
        let full = explanation.map { "\(summary)\n\n\($0)" } ?? summary
        let titleAndDescription: (String, String?) = summary.count > 256 ? ("Model fallback", full) : (summary, explanation)
        await send(Notices.updateOrTranscript(severity: "warning", title: titleAndDescription.0, description: titleAndDescription.1, supports: caps.notices, transcript: "**Model fallback:** \(full)"))
        if persistent { await syncModelAfterExternalSwitch(fallback) }
    }
}
