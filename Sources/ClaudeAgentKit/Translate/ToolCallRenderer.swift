// @author ixxxxoooo
// 工具调用渲染器:把 Claude 的 `tool_use`/`tool_result` 翻译成 ACP 的 `tool_call`/`tool_call_update`(标题、种类、内容、位置、终端事件)。

import ACPKit
import Foundation

/// 客户端声明的与工具渲染相关的能力。
public struct ToolRenderCapabilities: Sendable, Equatable {
    /// 声明了 `_meta.terminal_output`(Bash 输出走终端元数据)
    public var terminalOutput = false
    /// 声明了 `_meta.terminal_output_delta`(终端输出走增量元数据)
    public var terminalOutputDelta = false

    public init(terminalOutput: Bool = false, terminalOutputDelta: Bool = false) {
        self.terminalOutput = terminalOutput || terminalOutputDelta
        self.terminalOutputDelta = terminalOutputDelta
    }

    /// 从 `initialize.clientCapabilities` 解析。
    /// - Parameter capabilities: 客户端能力 JSON
    public init(clientCapabilities capabilities: JSONValue?) {
        let meta = capabilities?["_meta"]
        self.init(terminalOutput: meta?["terminal_output"]?.boolValue == true, terminalOutputDelta: meta?["terminal_output_delta"]?.boolValue == true)
    }
}

/// 一次工具调用(`tool_use` 块)。
public struct ToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// 工具调用「事实」:标题、种类与展示内容,与是否终端无关。
struct ToolFacts {
    var title: String
    var kind: String
    var command = false
    var display: [JSONValue] = []
    var change: [JSONValue] = []
    var locations: [JSONValue]?
}

/// 工具渲染器(纯函数式,无状态)。
public struct ToolCallRenderer: Sendable {
    public var capabilities: ToolRenderCapabilities

    public init(capabilities: ToolRenderCapabilities = .init()) {
        self.capabilities = capabilities
    }

    // MARK: 工具调用(tool_use)

    /// 首次出现的 `tool_call` 通知体。
    /// - Parameters:
    ///   - toolUse: 工具调用
    ///   - cwd: 会话工作目录(用于显示相对路径)
    ///   - previewContent: 覆盖默认内容(如预览 diff)
    public func toolCall(_ toolUse: ToolUse, cwd: String?, previewContent: [JSONValue]? = nil) -> JSONValue {
        let facts = Self.facts(toolUse.name, toolUse.input, cwd: cwd)
        var meta: [String: JSONValue] = ["claudeCode": ["toolName": .string(toolUse.name)]]
        if hasTerminal(facts) { meta["terminal_info"] = ["terminal_id": .string(toolUse.id)] }
        var update: [String: JSONValue] = [
            "_meta": .object(meta), "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call", "name": .string(toolUse.name),
            "rawInput": toolUse.input, "status": "pending", "title": .string(facts.title), "kind": .string(facts.kind),
            "content": .array(previewContent ?? toolUseContent(toolUse.id, facts)),
        ]
        if let locations = facts.locations { update["locations"] = .array(locations) }
        return .object(update)
    }

    /// 完整输入到达后对已上报工具调用的细化更新。
    public func refinement(_ toolUse: ToolUse, cwd: String?) -> JSONValue {
        let facts = Self.facts(toolUse.name, toolUse.input, cwd: cwd)
        var update: [String: JSONValue] = [
            "_meta": ["claudeCode": ["toolName": .string(toolUse.name)]], "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call_update",
            "rawInput": toolUse.input, "title": .string(facts.title), "kind": .string(facts.kind),
            "content": .array(toolUseContent(toolUse.id, facts)),
        ]
        if let locations = facts.locations { update["locations"] = .array(locations) }
        return .object(update)
    }

    /// 流式输入尚未完整时的部分细化(标题随参数逐步成形)。
    public func partialRefinement(id: String, name: String, input: JSONValue, cwd: String?) -> JSONValue {
        let facts = Self.facts(name, input, cwd: cwd)
        var update: [String: JSONValue] = [
            "_meta": ["claudeCode": ["toolName": .string(name)]], "toolCallId": .string(id), "sessionUpdate": "tool_call_update",
            "rawInput": input, "title": .string(facts.title), "kind": .string(facts.kind),
        ]
        if let locations = facts.locations { update["locations"] = .array(locations) }
        return .object(update)
    }

    /// 权限请求里携带的 `toolCall` 描述。
    /// - Parameters:
    ///   - toolUse: 工具调用
    ///   - cwd: 工作目录
    ///   - title: 覆盖标题
    ///   - previewContent: 预览内容(如 diff)
    ///   - fallbackContent: 无内容时的兜底内容
    ///   - meta: 额外 `_meta`
    public func permissionToolCall(_ toolUse: ToolUse, cwd: String?, title: String? = nil, previewContent: [JSONValue]? = nil, fallbackContent: [JSONValue]? = nil, meta: JSONValue? = nil) -> JSONValue {
        let facts = Self.facts(toolUse.name, toolUse.input, cwd: cwd)
        var content = previewContent ?? toolUseContent(toolUse.id, facts)
        if content.isEmpty, let fallbackContent { content = fallbackContent }
        var update: [String: JSONValue] = [
            "toolCallId": .string(toolUse.id), "name": .string(toolUse.name), "status": "pending", "rawInput": toolUse.input,
            "title": .string(title ?? facts.title), "kind": .string(facts.kind), "content": .array(content),
        ]
        if let locations = facts.locations { update["locations"] = .array(locations) }
        if let meta { update["_meta"] = meta }
        return .object(update)
    }

    // MARK: 工具结果(tool_result)

    /// 把工具结果翻译成一组 `tool_call_update`(可能先有终端输出,最后是终态更新)。
    /// - Parameters:
    ///   - toolUse: 对应的工具调用
    ///   - result: `tool_result` 块(含 `content`/`is_error`)
    ///   - structured: 用户消息的 `tool_use_result`(结构化结果)
    ///   - nonExecution: 工具未执行的原因(如被打断/取消)
    public func result(_ toolUse: ToolUse, result: JSONValue, structured: JSONValue?, nonExecution: JSONValue? = nil) -> [JSONValue] {
        var fields = resultFacts(toolUse, result: result, structured: structured)
        let command: JSONValue? = fields.removeValue(forKey: CommandResult.key)
        var resultMeta: [String: JSONValue] = [:]
        if let command {
            let output = command["output"]?.stringValue ?? ""
            let exitCode = command["exitCode"]
            let terminalId = toolUse.id.isEmpty ? result["tool_use_id"]?.nonEmptyString : toolUse.id
            if capabilities.terminalOutput, let terminalId {
                let payload: JSONValue = ["terminal_id": .string(terminalId), "data": .string(output)]
                fields["content"] = [["type": "terminal", "terminalId": .string(terminalId)]]
                resultMeta["terminal_info"] = ["terminal_id": .string(terminalId)]
                resultMeta[capabilities.terminalOutputDelta ? "terminal_output_delta" : "terminal_output"] = payload
                resultMeta["terminal_exit"] = ["terminal_id": .string(terminalId), "exit_code": exitCode ?? .null, "signal": .null]
            } else if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["content"] = [["type": "content", "content": ["type": "text", "text": .string("```console\n\(output.trimmingTrailingWhitespace())\n```")]]]
            }
        }
        var updates: [JSONValue] = []
        let terminalOutput = resultMeta["terminal_output_delta"] ?? resultMeta["terminal_output"]
        if let terminalOutput {
            let key = resultMeta["terminal_output_delta"] != nil ? "terminal_output_delta" : "terminal_output"
            updates.append(["_meta": [key: terminalOutput], "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call_update"])
        }
        var rawOutput: JSONValue?
        if terminalOutput == nil { rawOutput = Self.exitPlanModeRawOutput(toolUse.name, result["content"]) }
        fields.removeValue(forKey: "rawOutput")

        var claudeCode: [String: JSONValue] = ["toolName": .string(toolUse.name)]
        for (key, value) in nonExecution?.objectValue ?? [:] { claudeCode[key] = value }
        var meta: [String: JSONValue] = ["claudeCode": .object(claudeCode)]
        if let exit = resultMeta["terminal_exit"] { meta["terminal_exit"] = exit }
        var final: [String: JSONValue] = [
            "_meta": .object(meta), "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call_update",
            "status": .string(result["is_error"]?.boolValue == true ? "failed" : "completed"),
        ]
        if let rawOutput, !rawOutput.isNull { final["rawOutput"] = rawOutput }
        for (key, value) in fields { final[key] = value }
        updates.append(.object(final))
        return updates
    }

    /// PostToolUse 钩子回传的最终变更(Edit/Write 的结构化 diff)与工具响应标记。
    /// - Parameters:
    ///   - toolUse: 工具调用(只需 id 与 name)
    ///   - toolResponse: 钩子里的 `tool_response`
    /// - Returns: `tool_call_update` 通知体
    public func hookResult(_ toolUse: ToolUse, toolResponse: JSONValue) -> JSONValue {
        var update: [String: JSONValue] = [
            "_meta": ["claudeCode": ["toolResponse": toolResponse, "toolName": .string(toolUse.name)]],
            "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call_update",
        ]
        if ["Edit", "Write"].contains(toolUse.name) {
            let change = DiffContent.update(fromToolResponse: toolResponse)
            if let content = change.content { update["content"] = .array(content) }
            if let locations = change.locations { update["locations"] = .array(locations) }
        }
        return .object(update)
    }

    /// 被权限拒绝的工具调用。
    public func permissionDenied(toolCallId: String, toolName: String, parentToolUseId: String?, decisionReasonType: String?, decisionReason: String?, message: String?) -> JSONValue {
        let reason = decisionReason ?? message ?? ""
        var response: [String: JSONValue] = [:]
        if let decisionReasonType { response["decisionReasonType"] = .string(decisionReasonType) }
        if let decisionReason { response["decisionReason"] = .string(decisionReason) }
        if let message { response["message"] = .string(message) }
        var claudeCode: [String: JSONValue] = ["toolName": .string(toolName), "toolResponse": .object(response)]
        if let parentToolUseId { claudeCode["parentToolUseId"] = .string(parentToolUseId) }
        return [
            "sessionUpdate": "tool_call_update", "toolCallId": .string(toolCallId), "status": "failed",
            "content": [Self.textContent("Permission denied: \(reason)")],
            "_meta": ["claudeCode": .object(claudeCode)],
        ]
    }

    /// 回合结束时仍未返回结果的工具调用。
    /// - Parameters:
    ///   - toolCallId: 工具调用 ID
    ///   - ran: 工具是否已经开始执行
    ///   - cancelled: 回合是否被取消
    public func unfinished(toolCallId: String, ran: Bool, cancelled: Bool) -> JSONValue {
        let text = !ran ? "Claude stopped this tool call before it ran."
            : cancelled ? "The turn was cancelled before this tool call returned a result."
            : "Claude ended the turn without returning a result for this tool."
        return ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolCallId), "status": "failed", "content": [Self.textContent(text)]]
    }

    /// 终端工具在回合异常结束时补发的退出事件。
    public func terminalExit(_ toolUse: ToolUse) -> JSONValue? {
        guard hasTerminal(Self.facts(toolUse.name, toolUse.input, cwd: nil)) else { return nil }
        return ["terminal_exit": ["terminal_id": .string(toolUse.id), "exit_code": .null, "signal": .null]]
    }

    /// 工具运行中的心跳(已运行秒数)。
    public func progress(toolCallId: String, toolName: String?, parentToolUseId: String?, elapsedSeconds: Double?, subagentType: String?, subagentRetry: JSONValue?) -> JSONValue {
        var claudeCode: [String: JSONValue] = [:]
        if let toolName { claudeCode["toolName"] = .string(toolName) }
        if let parentToolUseId, !parentToolUseId.isEmpty { claudeCode["parentToolUseId"] = .string(parentToolUseId) }
        var response: [String: JSONValue] = [:]
        if let elapsedSeconds { response["elapsedTimeSeconds"] = .double(elapsedSeconds) }
        if let subagentType { response["subagentType"] = .string(subagentType) }
        if let subagentRetry { response["subagentRetry"] = subagentRetry }
        claudeCode["toolResponse"] = .object(response)
        return ["sessionUpdate": "tool_call_update", "toolCallId": .string(toolCallId), "status": "in_progress", "_meta": ["claudeCode": .object(claudeCode)]]
    }

    // MARK: 内部

    func hasTerminal(_ facts: ToolFacts) -> Bool { facts.command && capabilities.terminalOutput }

    func toolUseContent(_ toolCallId: String, _ facts: ToolFacts) -> [JSONValue] {
        let terminal = hasTerminal(facts)
        var content: [JSONValue] = []
        if terminal { content.append(["type": "terminal", "terminalId": .string(toolCallId)]) }
        content += facts.change
        if !terminal { content += facts.display }
        return content
    }

    static func textContent(_ text: String) -> JSONValue {
        ["type": "content", "content": ["type": "text", "text": .string(text)]]
    }
}

extension String {
    /// 去掉结尾的空白与换行。
    func trimmingTrailingWhitespace() -> String {
        var text = self
        while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
        return text
    }
}
