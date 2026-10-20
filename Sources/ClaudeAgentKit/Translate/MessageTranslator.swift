// @author ixxxxoooo
// 消息翻译器:把 `claude` 输出的 `stream_event`/`assistant`/`user` 消息翻译成 ACP `session/update` 的 update 体。
// 状态(工具缓存、已上报工具、流式分块)由翻译器自己维护,会话 actor 持有它。

import ACPKit
import Foundation

/// 流式阶段已经发给客户端的文本/思考分块,用于在完整 assistant 消息到达时去重。
struct StreamedBlock: Equatable {
    var index: Int
    var type: String
    var text: String
}

/// 正在流式拼接的工具入参(只为了在顶层逗号处提前细化标题)。
struct StreamedToolInput {
    var id: String
    var name: String
    var partialJSON = ""
    var inString = false
    var escaped = false
    var objectDepth = 0
    var arrayDepth = 0
    var lastTopLevelComma = -1
    var emittedThroughComma = -1

    /// 追加一段入参片段并扫描结构。
    /// - Parameter fragment: `input_json_delta` 的 `partial_json`
    /// - Returns: 顶层对象是否已闭合
    mutating func scan(_ fragment: String) -> Bool {
        let offset = partialJSON.utf16.count
        partialJSON += fragment
        var complete = false
        for (index, character) in fragment.enumerated() {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": objectDepth += 1
            case "}":
                objectDepth -= 1
                if objectDepth == 0 { complete = true }
            case "[": arrayDepth += 1
            case "]": arrayDepth -= 1
            case "," where objectDepth == 1 && arrayDepth == 0: lastTopLevelComma = offset + index
            default: break
            }
        }
        return complete
    }

    /// 取最近一个顶层逗号之前的入参前缀并补全成对象。
    func recoveredInput() -> JSONValue? {
        let utf16 = Array(partialJSON.utf16)
        guard lastTopLevelComma >= 0, lastTopLevelComma <= utf16.count else { return nil }
        let prefix = String(decoding: utf16[0..<lastTopLevelComma], as: UTF16.self) + "}"
        guard let value = JSONValue.parse(prefix), value.objectValue != nil else { return nil }
        return value
    }
}

/// 任务工具(TaskCreate 等)维护的计划条目。
struct TaskItem: Equatable {
    var subject: String
    var status: String
    var activeForm: String?
    var description: String?
}

/// 翻译选项。
struct TranslateOptions {
    var parentToolUseId: String?
    var messageId: String?
    /// 流式 `content_block_start` 时入参尚不完整
    var inputComplete: Bool?
    var toolUseResult: JSONValue?
    var toolResultMeta: JSONValue?
    var cancelled = false
}

/// 消息翻译器(由会话 actor 独占使用,非线程安全)。
struct MessageTranslator {
    var renderer: ToolCallRenderer
    var cwd: String
    /// 客户端是否声明了 `plan` 能力(决定是否发 `plan_update`)
    var supportsPlan = false
    private(set) var toolUseCache: [String: ToolUse] = [:]
    private(set) var emittedToolCalls: Set<String> = []
    private var streamedBlocks: [String: [StreamedBlock]] = [:]
    private var streamedToolInputs: [String: [Int: StreamedToolInput]] = [:]
    private(set) var taskOrder: [String] = []
    private(set) var taskState: [String: TaskItem] = [:]
    /// 当前流式消息的 API 消息 ID(用于分组气泡)
    var currentStreamMessageId: String?

    init(renderer: ToolCallRenderer, cwd: String) {
        self.renderer = renderer
        self.cwd = cwd
    }

    // MARK: 入口

    /// 翻译一条 `stream_event`。
    mutating func translateStreamEvent(_ message: JSONValue) -> [JSONValue] {
        guard let event = message["event"] else { return [] }
        let parent = message["parent_tool_use_id"]?.nonEmptyString
        let key = parent ?? ""
        var options = TranslateOptions(parentToolUseId: parent, messageId: currentStreamMessageId)
        switch event["type"]?.stringValue {
        case "message_start":
            currentStreamMessageId = event.at("message", "id")?.nonEmptyString
            streamedBlocks[key] = []
            streamedToolInputs[key] = nil
            return []
        case "message_stop":
            streamedToolInputs[key] = nil
            return []
        case "content_block_start":
            guard let block = event["content_block"] else { return [] }
            if Self.isToolUse(block), let index = event["index"]?.intValue {
                streamedToolInputs[key, default: [:]][index] = StreamedToolInput(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "")
            }
            options.inputComplete = false
            return translateBlocks([block], role: "assistant", options: options)
        case "content_block_delta":
            guard let delta = event["delta"] else { return [] }
            if delta["type"]?.stringValue == "input_json_delta" {
                return partialToolInput(event: event, delta: delta, key: key, parent: parent)
            }
            recordStreamed(delta: delta, index: event["index"]?.intValue ?? 0, parent: key)
            return translateBlocks([delta], role: "assistant", options: options)
        case "content_block_stop":
            if let index = event["index"]?.intValue {
                streamedToolInputs[key]?[index] = nil
                if streamedToolInputs[key]?.isEmpty == true { streamedToolInputs[key] = nil }
            }
            return []
        default:
            return []
        }
    }

    /// 翻译一条 `assistant` 或 `user` 消息(完整内容)。
    /// - Parameters:
    ///   - message: SDK 消息
    ///   - forwardSubagentText: 是否转发子 Agent 的文本与思考
    ///   - replay: 历史回放模式(用户文本也要回显,助手文本不做流式去重)
    mutating func translateMessage(_ message: JSONValue, forwardSubagentText: Bool, replay: Bool = false) -> [JSONValue] {
        let type = message["type"]?.stringValue ?? ""
        let parent = message["parent_tool_use_id"]?.nonEmptyString
        let key = parent ?? ""
        let inner = message["message"] ?? .null
        let role = inner["role"]?.stringValue ?? type
        var options = TranslateOptions(parentToolUseId: parent, messageId: Self.messageId(message))
        if type == "user" {
            options.toolUseResult = message["tool_use_result"]
            options.toolResultMeta = message["tool_result_meta"]
        }
        guard let content = inner["content"] else { return [] }
        if let text = content.stringValue {
            // 字符串内容:本地命令输出之外的纯文本用户消息不回显(由客户端自己渲染)
            if type == "user", !replay { return [] }
            return translateBlocks([["type": "text", "text": .string(text)]], role: role, options: options)
        }
        guard let blocks = content.arrayValue else { return [] }
        if type == "user", !replay, blocks.count == 1, blocks[0]["type"]?.stringValue == "text" { return [] }
        var kept = blocks
        if type == "assistant" {
            if parent == nil || forwardSubagentText {
                kept = replay ? blocks : Self.unstreamedRemainder(blocks, streamed: streamedBlocks[key] ?? [])
            } else {
                kept = blocks.filter { !["text", "thinking"].contains($0["type"]?.stringValue ?? "") }
            }
            streamedBlocks[key] = []
        }
        return translateBlocks(kept, role: role, options: options)
    }

    /// 一次回合结束后清理单回合状态(流式分块、入参缓冲)。
    mutating func resetTurnState() {
        streamedBlocks.removeAll()
        streamedToolInputs.removeAll()
    }

    /// 对话重置(`/clear`):清空工具与任务状态。
    mutating func resetConversation() {
        toolUseCache.removeAll()
        emittedToolCalls.removeAll()
        resetTurnState()
        taskOrder.removeAll()
        taskState.removeAll()
    }

    /// 仍未返回结果的已上报工具调用 ID。
    var unfinishedToolCallIds: [String] {
        emittedToolCalls.sorted()
    }

    /// 权限/征询前确保工具卡已上报(与流式上报去重)。
    /// - Returns: 首次上报时返回 `tool_call` 通知体,已上报返回 nil
    mutating func ensureEmitted(_ toolUse: ToolUse, parent: String?, previewContent: [JSONValue]? = nil) -> JSONValue? {
        toolUseCache[toolUse.id] = toolUseCache[toolUse.id] ?? toolUse
        guard !emittedToolCalls.contains(toolUse.id) else { return nil }
        emittedToolCalls.insert(toolUse.id)
        return Self.stamp(renderer.toolCall(toolUse, cwd: cwd, previewContent: previewContent), parent: parent)
    }

    /// 查询缓存里的工具调用。
    func toolUse(id: String) -> ToolUse? { toolUseCache[id] }

    /// 标记某工具调用已结束(不再算未完成)。
    mutating func forgetToolCall(_ id: String) {
        emittedToolCalls.remove(id)
    }

    /// 任务工具维护的计划条目(含进行中任务的 `activeForm`)。
    var taskPlanEntries: [JSONValue] {
        taskOrder.compactMap { taskState[$0] }.map { task in
            ["content": .string(task.status == "in_progress" ? (task.activeForm ?? task.subject) : task.subject), "status": .string(task.status), "priority": "medium"]
        }
    }

    /// 钩子 `TaskCreated`:登记新任务。
    /// - Returns: 计划是否有变化
    mutating func taskCreated(id: String, subject: String, description: String?) -> Bool {
        guard taskState[id] == nil else { return false }
        setTask(id, TaskItem(subject: subject, status: "pending", description: description))
        return true
    }

    /// 钩子 `TaskCompleted`:标记任务完成。
    /// - Returns: 计划是否有变化
    mutating func taskCompleted(id: String) -> Bool {
        guard var existing = taskState[id], existing.status != "completed" else { return false }
        existing.status = "completed"
        taskState[id] = existing
        return true
    }

    // MARK: 块翻译

    static func isToolUse(_ block: JSONValue) -> Bool {
        ["tool_use", "server_tool_use", "mcp_tool_use"].contains(block["type"]?.stringValue ?? "") && block["id"]?.stringValue != nil
    }

    static func isTaskTool(_ name: String) -> Bool { ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"].contains(name) }

    static func messageId(_ message: JSONValue) -> String? {
        if message["type"]?.stringValue == "assistant", let id = message.at("message", "id")?.nonEmptyString { return id }
        return message["uuid"]?.nonEmptyString
    }

    private mutating func translateBlocks(_ content: [JSONValue], role: String, options: TranslateOptions) -> [JSONValue] {
        var output: [JSONValue] = []
        let chunkKind = role == "assistant" ? "agent_message_chunk" : "user_message_chunk"
        let toolResultCount = content.filter { $0["type"]?.stringValue == "tool_result" }.count
        let toolUseResult = toolResultCount == 1 ? options.toolUseResult : nil
        let resultMeta = Self.parseToolResultMeta(options.toolResultMeta)
        for chunk in content {
            var update: JSONValue?
            switch chunk["type"]?.stringValue ?? "" {
            case "text", "text_delta":
                if let text = chunk["text"]?.nonEmptyString { update = ["sessionUpdate": .string(chunkKind), "content": ["type": "text", "text": .string(text)]] }
            case "image":
                let source = chunk["source"]
                let isBase64 = source?["type"]?.stringValue == "base64"
                var image: [String: JSONValue] = ["type": "image", "data": isBase64 ? (source?["data"] ?? "") : "", "mimeType": isBase64 ? (source?["media_type"] ?? "") : ""]
                if source?["type"]?.stringValue == "url", let url = source?["url"] { image["uri"] = url }
                update = ["sessionUpdate": .string(chunkKind), "content": .object(image)]
            case "thinking", "thinking_delta":
                if let text = chunk["thinking"]?.nonEmptyString { update = ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": .string(text)]] }
            case "tool_use", "server_tool_use", "mcp_tool_use":
                update = toolUseUpdate(chunk, options: options)
            case "tool_result", "tool_search_tool_result", "web_fetch_tool_result", "web_search_tool_result", "code_execution_tool_result",
                 "bash_code_execution_tool_result", "text_editor_code_execution_tool_result", "mcp_tool_result":
                let (results, approved) = toolResultUpdates(chunk, options: options, structured: toolUseResult, meta: resultMeta)
                for item in results { output.append(Self.stamp(item, parent: options.parentToolUseId)) }
                if let approved { output.append(approved) }
            default:
                break
            }
            if var value = update {
                value = Self.stamp(value, parent: options.parentToolUseId)
                value = Self.applyMessageId(value, options.messageId)
                output.append(value)
            }
        }
        return output.map { Self.applyMessageId($0, options.messageId) }
    }

    private mutating func toolUseUpdate(_ chunk: JSONValue, options: TranslateOptions) -> JSONValue? {
        guard let id = chunk["id"]?.stringValue else { return nil }
        let name = chunk["name"]?.stringValue ?? ""
        let toolUse = ToolUse(id: id, name: name, input: chunk["input"] ?? .object([:]))
        toolUseCache[id] = toolUse
        if name == "TodoWrite" {
            guard let todos = toolUse.input["todos"]?.arrayValue else { return nil }
            return ["sessionUpdate": "plan", "entries": .array(todos.map { Self.planEntry($0) })]
        }
        if Self.isTaskTool(name) { return nil }
        let alreadyEmitted = emittedToolCalls.contains(id)
        emittedToolCalls.insert(id)
        if alreadyEmitted, options.inputComplete == false { return nil }
        return alreadyEmitted ? renderer.refinement(toolUse, cwd: cwd) : renderer.toolCall(toolUse, cwd: cwd)
    }

    /// 返回(按顺序的更新列表,最后一个为终态更新;批准的计划更新)。
    private mutating func toolResultUpdates(_ chunk: JSONValue, options: TranslateOptions, structured: JSONValue?, meta: [String: JSONValue]?) -> (updates: [JSONValue], approvedPlan: JSONValue?) {
        guard let toolUseId = chunk["tool_use_id"]?.stringValue else { return ([], nil) }
        let wasEmitted = emittedToolCalls.contains(toolUseId)
        emittedToolCalls.remove(toolUseId)
        let nonExecution = meta?[toolUseId]
        let isError = chunk["is_error"]?.boolValue == true
        guard let toolUse = toolUseCache[toolUseId] else {
            guard wasEmitted else { return ([], nil) }
            return ([["sessionUpdate": "tool_call_update", "toolCallId": .string(toolUseId), "status": .string(isError ? "failed" : "completed"), "rawOutput": chunk["content"] ?? .null]], nil)
        }
        defer { toolUseCache[toolUseId] = nil }
        var updates: [JSONValue] = []
        if Self.isTaskTool(toolUse.name) {
            if wasEmitted {
                updates.append(Self.passthroughResult(toolUse, chunk: chunk, parent: options.parentToolUseId, nonExecution: nonExecution))
            }
            if !isError, applyTaskResult(toolUse, chunk: chunk, structured: structured) {
                updates.append(["sessionUpdate": "plan", "entries": .array(taskPlanEntries)])
            }
            return (updates, nil)
        }
        if toolUse.name == "TodoWrite" { return ([], nil) }
        updates = renderer.result(toolUse, result: chunk, structured: structured, nonExecution: nonExecution)
        var approved: JSONValue?
        if toolUse.name == "ExitPlanMode", supportsPlan, options.parentToolUseId == nil, !isError, let plan = Self.approvedPlan(toolUse.input, structured) {
            approved = ["sessionUpdate": "plan_update", "plan": ["type": "markdown", "planId": "plan-mode", "content": .string(plan)]]
        }
        return (updates, approved)
    }

    private static func passthroughResult(_ toolUse: ToolUse, chunk: JSONValue, parent: String?, nonExecution: JSONValue?) -> JSONValue {
        var claudeCode: [String: JSONValue] = ["toolName": .string(toolUse.name)]
        for (key, value) in nonExecution?.objectValue ?? [:] { claudeCode[key] = value }
        if let parent { claudeCode["parentToolUseId"] = .string(parent) }
        return [
            "_meta": ["claudeCode": .object(claudeCode)], "toolCallId": .string(toolUse.id), "sessionUpdate": "tool_call_update",
            "status": .string(chunk["is_error"]?.boolValue == true ? "failed" : "completed"), "rawOutput": chunk["content"] ?? .null,
        ]
    }

    // MARK: 流式入参

    private mutating func partialToolInput(event: JSONValue, delta: JSONValue, key: String, parent: String?) -> [JSONValue] {
        guard let index = event["index"]?.intValue, var state = streamedToolInputs[key]?[index] else { return [] }
        let complete = state.scan(delta["partial_json"]?.stringValue ?? "")
        if complete {
            streamedToolInputs[key]?[index] = nil
            if streamedToolInputs[key]?.isEmpty == true { streamedToolInputs[key] = nil }
            return []
        }
        guard state.lastTopLevelComma > state.emittedThroughComma else {
            streamedToolInputs[key]?[index] = state
            return []
        }
        state.emittedThroughComma = state.lastTopLevelComma
        streamedToolInputs[key]?[index] = state
        guard let input = state.recoveredInput(), !(state.name == "TodoWrite" || Self.isTaskTool(state.name)) else { return [] }
        var update = renderer.partialRefinement(id: state.id, name: state.name, input: input, cwd: cwd)
        update = Self.stamp(update, parent: parent)
        return [Self.applyMessageId(update, currentStreamMessageId)]
    }

    private mutating func recordStreamed(delta: JSONValue, index: Int, parent key: String) {
        let type: String
        let text: String
        switch delta["type"]?.stringValue {
        case "text_delta": type = "text"; text = delta["text"]?.stringValue ?? ""
        case "thinking_delta": type = "thinking"; text = delta["thinking"]?.stringValue ?? ""
        default: return
        }
        guard !text.isEmpty else { return }
        var blocks = streamedBlocks[key] ?? []
        if var last = blocks.last, last.index == index, last.type == type {
            last.text += text
            blocks[blocks.count - 1] = last
        } else {
            blocks.append(StreamedBlock(index: index, type: type, text: text))
        }
        streamedBlocks[key] = blocks
    }

    /// 完整 assistant 消息里去掉流式阶段已发送的文本/思考部分。
    static func unstreamedRemainder(_ blocks: [JSONValue], streamed: [StreamedBlock]) -> [JSONValue] {
        var kept: [JSONValue] = []
        var position = 0
        for item in blocks {
            let type = item["type"]?.stringValue ?? ""
            guard type == "text" || type == "thinking" else { kept.append(item); continue }
            let key = type == "text" ? "text" : "thinking"
            let full = item[key]?.stringValue ?? ""
            if full.isEmpty { continue }
            if position < streamed.count {
                let candidate = streamed[position]
                if candidate.type == type, !candidate.text.isEmpty, full.hasPrefix(candidate.text) {
                    position += 1
                    let remainder = String(full.dropFirst(candidate.text.count))
                    if remainder.isEmpty { continue }
                    var object = item.objectValue ?? [:]
                    object[key] = .string(remainder)
                    kept.append(.object(object))
                    continue
                }
            }
            kept.append(item)
        }
        return kept
    }

    // MARK: 任务计划

    private mutating func setTask(_ id: String, _ item: TaskItem) {
        if taskState[id] == nil { taskOrder.append(id) }
        taskState[id] = item
    }

    private mutating func applyTaskResult(_ toolUse: ToolUse, chunk: JSONValue, structured: JSONValue?) -> Bool {
        let content = chunk["content"]
        switch toolUse.name {
        case "TaskCreate":
            guard let id = TaskOutputParser.createdTaskId(structured) ?? TaskOutputParser.createdTaskId(content) else { return false }
            setTask(id, TaskItem(subject: toolUse.input["subject"]?.stringValue ?? "", status: "pending", activeForm: toolUse.input["activeForm"]?.stringValue, description: toolUse.input["description"]?.stringValue))
            return true
        case "TaskUpdate":
            let taskId = toolUse.input["taskId"]?.stringValue
            let output = TaskOutputParser.update(structured, expected: taskId) ?? TaskOutputParser.update(content, expected: taskId)
            if let output, !(output.success && output.taskId == taskId) { return false }
            guard let taskId else { return false }
            if toolUse.input["status"]?.stringValue == "deleted" {
                taskState[taskId] = nil
                taskOrder.removeAll { $0 == taskId }
                return true
            }
            let existing = taskState[taskId]
            guard let subject = toolUse.input["subject"]?.stringValue ?? existing?.subject else { return false }
            setTask(taskId, TaskItem(
                subject: subject, status: toolUse.input["status"]?.stringValue ?? existing?.status ?? "pending",
                activeForm: toolUse.input["activeForm"]?.stringValue ?? existing?.activeForm,
                description: toolUse.input["description"]?.stringValue ?? existing?.description
            ))
            return true
        case "TaskList":
            guard let tasks = TaskOutputParser.list(structured) ?? TaskOutputParser.list(content) else { return false }
            let previous = taskState
            taskState.removeAll()
            taskOrder.removeAll()
            for task in tasks {
                setTask(task.id, TaskItem(subject: task.subject, status: task.status, activeForm: previous[task.id]?.activeForm, description: previous[task.id]?.description))
            }
            return true
        default:
            return false
        }
    }

    // MARK: 工具函数

    static func planEntry(_ todo: JSONValue) -> JSONValue {
        let status = todo["status"]?.stringValue ?? "pending"
        let text = status == "in_progress" ? (todo["activeForm"]?.nonEmptyString ?? todo["content"]?.stringValue ?? "") : (todo["content"]?.stringValue ?? "")
        return ["content": .string(text), "status": .string(status), "priority": "medium"]
    }

    static func approvedPlan(_ input: JSONValue, _ output: JSONValue?) -> String? {
        if output?["isAgent"]?.boolValue == true || output?["awaitingLeaderApproval"]?.boolValue == true { return nil }
        let plan = output?["plan"]?.stringValue ?? input["plan"]?.stringValue
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parseToolResultMeta(_ raw: JSONValue?) -> [String: JSONValue]? {
        guard let entries = raw?.arrayValue else { return nil }
        var result: [String: JSONValue] = [:]
        for entry in entries {
            guard let id = entry["id"]?.stringValue, let kind = entry["non_execution_kind"]?.stringValue else { continue }
            var value: [String: JSONValue] = ["nonExecutionKind": .string(kind)]
            if let feedback = entry["user_feedback"]?.stringValue { value["userFeedback"] = .string(feedback) }
            result[id] = .object(value)
        }
        return result.isEmpty ? nil : result
    }

    static func stamp(_ update: JSONValue, parent: String?) -> JSONValue {
        guard let parent, var object = update.objectValue else { return update }
        var meta = object["_meta"]?.objectValue ?? [:]
        var claudeCode = meta["claudeCode"]?.objectValue ?? [:]
        claudeCode["parentToolUseId"] = .string(parent)
        meta["claudeCode"] = .object(claudeCode)
        object["_meta"] = .object(meta)
        return .object(object)
    }

    static func applyMessageId(_ update: JSONValue, _ messageId: String?) -> JSONValue {
        guard let messageId, var object = update.objectValue,
              ["agent_message_chunk", "user_message_chunk", "agent_thought_chunk"].contains(object["sessionUpdate"]?.stringValue ?? "") else { return update }
        object["messageId"] = .string(messageId)
        return .object(object)
    }
}

/// 任务工具输出解析(结构化 JSON 或文本摘要两种形态)。
enum TaskOutputParser {
    struct ListedTask { var id: String; var subject: String; var status: String }

    private static func jsonOutput(_ content: JSONValue?, accept: (JSONValue) -> Bool) -> JSONValue? {
        guard let content else { return nil }
        if let text = content.stringValue {
            if let parsed = JSONValue.parse(text), accept(parsed) { return parsed }
            return nil
        }
        if content.objectValue != nil { return accept(content) ? content : nil }
        for block in content.arrayValue ?? [] where block["type"]?.stringValue == "text" {
            if let text = block["text"]?.stringValue, let parsed = JSONValue.parse(text), accept(parsed) { return parsed }
        }
        return nil
    }

    private static func texts(_ content: JSONValue?) -> [String] {
        guard let content else { return [] }
        if let text = content.stringValue { return [text] }
        return (content.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
    }

    static func createdTaskId(_ content: JSONValue?) -> String? {
        if let parsed = jsonOutput(content, accept: { $0["task"]?["id"]?.stringValue != nil }) { return parsed["task"]?["id"]?.stringValue }
        for text in texts(content) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Task #"), let range = trimmed.range(of: " created successfully: ") {
                return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<range.lowerBound])
            }
        }
        return nil
    }

    static func update(_ content: JSONValue?, expected: String?) -> (success: Bool, taskId: String)? {
        if let parsed = jsonOutput(content, accept: { $0["success"]?.boolValue != nil && $0["taskId"]?.stringValue != nil && $0["updatedFields"]?.arrayValue != nil }) {
            return (parsed["success"]?.boolValue ?? false, parsed["taskId"]?.stringValue ?? "")
        }
        for text in texts(content) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Task #"), trimmed.hasSuffix(" not found") {
                return (false, String(trimmed.dropFirst(6).dropLast(" not found".count)))
            }
            if trimmed == "Failed to delete task", let expected { return (false, expected) }
        }
        return nil
    }

    static func list(_ content: JSONValue?) -> [ListedTask]? {
        let valid: Set<String> = ["pending", "in_progress", "completed"]
        if let parsed = jsonOutput(content, accept: { value in
            guard let tasks = value["tasks"]?.arrayValue else { return false }
            return tasks.allSatisfy { $0["id"]?.stringValue != nil && $0["subject"]?.stringValue != nil && valid.contains($0["status"]?.stringValue ?? "") }
        }) {
            return (parsed["tasks"]?.arrayValue ?? []).map { ListedTask(id: $0["id"]?.stringValue ?? "", subject: $0["subject"]?.stringValue ?? "", status: $0["status"]?.stringValue ?? "pending") }
        }
        for text in texts(content) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "No tasks found" { return [] }
            var tasks: [ListedTask] = []
            for line in trimmed.components(separatedBy: "\n") {
                guard line.hasPrefix("#"), let space = line.firstIndex(of: " ") else { tasks = []; break }
                let id = String(line[line.index(after: line.startIndex)..<space])
                let rest = line[line.index(after: space)...]
                guard let close = rest.firstIndex(of: "]"), rest.hasPrefix("["),
                      valid.contains(String(rest[rest.index(after: rest.startIndex)..<close])) else { tasks = []; break }
                var subject = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if let marker = subject.range(of: " [blocked by ", options: .backwards), subject.hasSuffix("]") { subject = String(subject[..<marker.lowerBound]) }
                if let owner = subject.range(of: " (", options: .backwards), subject.hasSuffix(")") { subject = String(subject[..<owner.lowerBound]) }
                tasks.append(ListedTask(id: id, subject: subject, status: String(rest[rest.index(after: rest.startIndex)..<close])))
            }
            if !tasks.isEmpty { return tasks }
        }
        return nil
    }
}
