// @author ixxxxoooo
// 钩子:`PostToolUse`(Diff 终稿回写、进入计划模式)、`PostModelSwitch`、`PostCompact`、`TaskCreated/TaskCompleted`。

import ACPKit
import Foundation

extension ClaudeSession {
    /// 登记首次出现的工具调用,供 `PostToolUse` 回写。
    func registerHook(for update: JSONValue) {
        guard update["sessionUpdate"]?.stringValue == "tool_call", let toolCallId = update["toolCallId"]?.stringValue,
              let name = update.at("_meta", "claudeCode", "toolName")?.stringValue else { return }
        guard !MessageTranslator.isTaskTool(name), name != "TodoWrite", hookedTools[toolCallId] == nil else { return }
        hookedTools[toolCallId] = (name, update.at("_meta", "claudeCode", "parentToolUseId")?.nonEmptyString)
    }

    nonisolated func hookCallback(callbackId: String, input: JSONValue, toolUseId: String?) async -> JSONValue {
        await runHook(callbackId: callbackId, input: input, toolUseId: toolUseId)
        return ["continue": true]
    }

    private func runHook(callbackId: String, input: JSONValue, toolUseId: String?) async {
        guard let kind = hookIds[callbackId] else { return }
        switch kind {
        case .postToolUse:
            guard input["hook_event_name"]?.stringValue == "PostToolUse" else { return }
            if input["tool_name"]?.stringValue == "EnterPlanMode" {
                await send(["sessionUpdate": "current_mode_update", "currentModeId": "plan"])
                await updateConfigOption(PermissionModes.configId, .string("plan"))
            }
            guard let toolUseId, let entry = hookedTools.removeValue(forKey: toolUseId) else { return }
            let response = input["tool_response"] ?? .null
            let toolUse = ToolUse(id: toolUseId, name: entry.name, input: input["tool_input"] ?? .null)
            let update = MessageTranslator.stamp(translator.renderer.hookResult(toolUse, toolResponse: response), parent: entry.parent)
            await send(update)
        case .postModelSwitch:
            guard input["hook_event_name"]?.stringValue == "PostModelSwitch" else { return }
            let source = input["source"]?.stringValue
            guard source != "sdk", source != "resume", let target = input["to_model"]?.stringValue else { return }
            await syncModelAfterExternalSwitch(target)
        case .postCompact:
            break
        case .taskCreated:
            guard input["hook_event_name"]?.stringValue == "TaskCreated", let taskId = input["task_id"]?.stringValue,
                  let subject = input["task_subject"]?.nonEmptyString else { return }
            if translator.taskCreated(id: taskId, subject: subject, description: input["task_description"]?.stringValue) { await publishTaskPlan() }
        case .taskCompleted:
            guard input["hook_event_name"]?.stringValue == "TaskCompleted", let taskId = input["task_id"]?.stringValue else { return }
            if translator.taskCompleted(id: taskId) { await publishTaskPlan() }
        }
    }

    /// 推送任务工具维护的计划。
    func publishTaskPlan() async {
        await send(["sessionUpdate": "plan", "entries": .array(translator.taskPlanEntries)])
    }
}
