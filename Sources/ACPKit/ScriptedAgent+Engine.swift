// @author ixxxxoooo
// 场景引擎的执行端:把 `ScenarioStep` 翻译成 ACP 的 `session/update` 与反向请求。
// 子 Agent 内部的更新统一带上 `_meta.claudeCode.parentToolUseId`,与真实适配器的行为一致。

import Foundation

extension ScriptedAgent {
    // MARK: 基础发送

    /// 发送一条会话更新;`parent` 非空时附加父工具调用标记(子 Agent 内部更新)。
    /// - Parameters:
    ///   - sessionId: 会话
    ///   - parent: 父工具调用 ID
    ///   - payload: 更新体
    func emit(_ sessionId: String, parent: String?, _ payload: [String: JSONValue]) async {
        var body = payload
        if let parent, !parent.isEmpty {
            body["_meta"] = ["claudeCode": ["parentToolUseId": .string(parent)]]
        }
        await update(sessionId, .object(body))
    }

    /// 按节奏缩放后的停顿(测试里 `chunkDelayMillis` 很小,停顿随之缩短)。
    func scaledDelay(_ millis: Int) async {
        let scaled = max(0, millis * chunkDelayMillis / 15)
        if scaled > 0 { try? await Task.sleep(for: .milliseconds(scaled)) }
    }

    /// 回放期间不停顿的版本(其余会话沿用统一节奏)。
    func pause(_ sessionId: String) async {
        if !replaying.contains(sessionId) { await pause() }
    }

    // MARK: 步骤执行

    /// 依次执行一组步骤。
    /// - Parameters:
    ///   - steps: 步骤
    ///   - ctx: 上下文
    ///   - parent: 父工具调用 ID(子 Agent 内部时非空)
    /// - Returns: 执行结果;被取消或被拒绝时提前返回
    func runSteps(_ steps: [ScenarioStep], ctx: ScenarioContext, parent: String? = nil) async throws -> ScenarioOutcome {
        for step in steps {
            if cancelled.contains(ctx.sessionId) { return .cancelled }
            let outcome = try await runStep(step, ctx: ctx, parent: parent)
            if outcome != .finished { return outcome }
        }
        return .finished
    }

    /// 执行单个步骤。
    func runStep(_ step: ScenarioStep, ctx: ScenarioContext, parent: String?) async throws -> ScenarioOutcome {
        let sessionId = ctx.sessionId
        switch step {
        case .thought(let pieces):
            for piece in pieces {
                await emit(sessionId, parent: parent, ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": .string(piece)]])
                await pause(sessionId)
                if cancelled.contains(sessionId) { return .cancelled }
            }
        case .text(let pieces):
            for piece in pieces {
                await emit(sessionId, parent: parent, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(piece)]])
                await pause(sessionId)
                if cancelled.contains(sessionId) { return .cancelled }
            }
        case .user(let text):
            await emit(sessionId, parent: parent, ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": .string(text)]])
        case .tool(let tool):
            await runTool(tool, ctx: ctx, parent: parent)
        case .permission(let permission):
            return try await runPermission(permission, ctx: ctx, parent: parent)
        case .subagent(let sub):
            return try await runSubagentStep(sub, ctx: ctx, parent: parent)
        case .parallel(let groups):
            return try await runParallel(groups, ctx: ctx, parent: parent)
        case .plan(let items):
            let entries = items.map { item -> JSONValue in
                ["content": .string(item.content), "priority": .string(item.priority), "status": .string(item.status)]
            }
            await emit(sessionId, parent: parent, ["sessionUpdate": "plan", "entries": .array(entries)])
        case .planDoc(let markdown):
            await emit(sessionId, parent: parent, ["sessionUpdate": "plan_update", "plan": ["type": "markdown", "content": .string(markdown)]])
        case .notice(let severity, let title, let detail):
            var body: [String: JSONValue] = ["sessionUpdate": "notice", "severity": .string(severity), "title": .string(title)]
            if let detail { body["description"] = .string(detail) }
            await emit(sessionId, parent: parent, body)
        case .agentNotify(let level, let text):
            await emit(sessionId, parent: parent, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(text)],
                                                    "_meta": ["piAcp": ["notify": ["level": .string(level)]]]])
        case .usage(let used, let size, let cost):
            var body: [String: JSONValue] = ["sessionUpdate": "usage_update", "used": .int(used), "size": .int(size)]
            if let cost { body["cost"] = ["amount": .double(cost), "currency": "USD"] }
            await emit(sessionId, parent: nil, body)
        case .title(let title):
            await emit(sessionId, parent: nil, ["sessionUpdate": "session_info_update", "title": .string(title)])
        case .mode(let mode):
            modes[sessionId] = mode
            await emit(sessionId, parent: nil, ["sessionUpdate": "current_mode_update", "currentModeId": .string(mode)])
        case .delay(let millis):
            await scaledDelay(millis)
        case .hold:
            while !cancelled.contains(sessionId) {
                // 冻结期间收到的引导消息立即回显,便于验证「运行中发送」
                for extra in steered.removeValue(forKey: sessionId) ?? [] {
                    await emit(sessionId, parent: parent, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("(已收到引导:\(extra))\n\n")]])
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return .cancelled
        case .builtin(let builtin):
            switch builtin {
            case .edit: try await runEdit(sessionId: sessionId)
            case .ask: try await runAsk(sessionId: sessionId)
            case .terminal: try await runTerminal(sessionId: sessionId)
            case .longRunning: try await runHold(sessionId: sessionId)
            }
        }
        return cancelled.contains(sessionId) ? .cancelled : .finished
    }

    // MARK: 工具

    /// 工具调用:进行中 → 完成/失败;冻结态只发开头。
    func runTool(_ tool: ScenarioTool, ctx: ScenarioContext, parent: String?) async {
        let sessionId = ctx.sessionId
        let toolId = ctx.scoped(tool.id)
        var content = tool.extra
        if let output = tool.output { content.append(["type": "content", "content": ["type": "text", "text": .string(output)]]) }
        var start: [String: JSONValue] = [
            "sessionUpdate": "tool_call", "toolCallId": .string(toolId), "title": .string(tool.title), "kind": .string(tool.kind),
            "name": .string(tool.name), "status": tool.finish == .pending ? "pending" : "in_progress",
            "rawInput": tool.input, "locations": tool.locations,
        ]
        let frozen = tool.finish == .running || tool.finish == .pending
        if frozen, !content.isEmpty { start["content"] = .array(content) }
        await emit(sessionId, parent: parent, start)
        await pause(sessionId)
        guard !frozen else { return }
        await emit(sessionId, parent: parent, [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(toolId),
            "status": tool.finish == .failed ? "failed" : "completed", "content": .array(content),
        ])
        await pause(sessionId)
    }

    /// 需要批准的工具调用:待处理 → 请求权限 → 进行中 → 完成;拒绝/取消则失败。
    func runPermission(_ permission: ScenarioPermission, ctx: ScenarioContext, parent: String?) async throws -> ScenarioOutcome {
        let sessionId = ctx.sessionId
        let tool = permission.tool
        let toolId = ctx.scoped(tool.id)
        await emit(sessionId, parent: parent, [
            "sessionUpdate": "tool_call", "toolCallId": .string(toolId), "title": .string(tool.title), "kind": .string(tool.kind),
            "name": .string(tool.name), "status": "pending", "rawInput": tool.input, "locations": tool.locations,
        ])
        let options = Self.permissionOptions(permission.options)
        let response = try await connection.request("session/request_permission", params: [
            "sessionId": .string(sessionId),
            "toolCall": [
                "toolCallId": .string(toolId), "title": .string(tool.title), "kind": .string(tool.kind),
                "name": .string(tool.name), "rawInput": tool.input, "content": .array(tool.extra),
            ],
            "options": .array(options),
        ])
        let outcome = response["outcome"]?["outcome"]?.stringValue
        let chosenId = response["outcome"]?["optionId"]?.stringValue
        let chosenKind = options.first { $0["optionId"]?.stringValue == chosenId }?["kind"]?.stringValue ?? "reject_once"
        if outcome == "cancelled" || cancelled.contains(sessionId) {
            await emit(sessionId, parent: parent, ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": "failed"])
            return .cancelled
        }
        if chosenKind.hasPrefix("reject") {
            await emit(sessionId, parent: parent, ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": "failed"])
            if !permission.rejectedText.isEmpty {
                await emit(sessionId, parent: parent, ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(permission.rejectedText)]])
            }
            return .rejected
        }
        await emit(sessionId, parent: parent, ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolId), "status": "in_progress"])
        await pause(sessionId)
        var content = tool.extra
        if let output = tool.output { content.append(["type": "content", "content": ["type": "text", "text": .string(output)]]) }
        await emit(sessionId, parent: parent, [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(toolId),
            "status": tool.finish == .failed ? "failed" : "completed", "content": .array(content),
        ])
        return .finished
    }

    /// 权限选项集合。
    static func permissionOptions(_ kind: ScenarioPermissionOptions) -> [JSONValue] {
        switch kind {
        case .standard:
            return [
                ["optionId": "allow", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "reject", "name": "拒绝", "kind": "reject_once"],
            ]
        case .withAlways:
            return [
                ["optionId": "allow", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "always", "name": "始终允许", "kind": "allow_always"],
                ["optionId": "reject", "name": "拒绝", "kind": "reject_once"],
            ]
        case .plan:
            return [
                ["optionId": "acceptEdits", "name": "批准并自动接受编辑", "kind": "allow_always"],
                ["optionId": "default", "name": "批准并逐项确认", "kind": "allow_once"],
                ["optionId": "plan", "name": "继续规划", "kind": "reject_once"],
            ]
        }
    }

    // MARK: 子 Agent 与并行

    /// 子 Agent:父工具调用 + 带父 ID 的内部更新;`.running` 时父卡片保持进行中(后台子 Agent)。
    func runSubagentStep(_ sub: ScenarioSubagent, ctx: ScenarioContext, parent: String?) async throws -> ScenarioOutcome {
        let subId = ctx.scoped(sub.id)
        var input: [String: JSONValue] = ["description": .string(sub.title), "run_in_background": .bool(sub.background)]
        if let type = sub.agentType { input["subagent_type"] = .string(type) }
        await emit(ctx.sessionId, parent: parent, [
            "sessionUpdate": "tool_call", "toolCallId": .string(subId), "title": .string(sub.title), "kind": "other",
            "name": "Task", "status": "in_progress", "rawInput": .object(input),
        ])
        let outcome = try await runSteps(sub.children, ctx: ctx, parent: subId)
        if outcome == .cancelled { return .cancelled }
        guard sub.finish == .completed || sub.finish == .failed else { return .finished }
        var update: [String: JSONValue] = [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(subId),
            "status": sub.finish == .failed ? "failed" : "completed",
        ]
        if let result = sub.result { update["content"] = [["type": "content", "content": ["type": "text", "text": .string(result)]]] }
        await emit(ctx.sessionId, parent: parent, update)
        return .finished
    }

    /// 并行执行多组步骤(并行子 Agent)。
    func runParallel(_ groups: [[ScenarioStep]], ctx: ScenarioContext, parent: String?) async throws -> ScenarioOutcome {
        try await withThrowingTaskGroup(of: ScenarioOutcome.self) { group in
            for steps in groups {
                group.addTask { try await self.runSteps(steps, ctx: ctx, parent: parent) }
            }
            var result = ScenarioOutcome.finished
            for try await outcome in group where outcome != .finished { result = outcome }
            return result
        }
    }
}
