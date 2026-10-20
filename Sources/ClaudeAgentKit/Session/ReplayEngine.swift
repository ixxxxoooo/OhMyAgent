// @author ixxxxoooo
// 历史回放:把转录里的 user/assistant 消息按序翻译成 `session/update`,供 `session/load` 重放会话内容。

import ACPKit
import Foundation

/// 回放结果:要发送的更新与消息 ID → UUID 映射(分叉点定位用)。
struct ReplayOutput {
    var updates: [JSONValue] = []
    var messageIdToUuid: [String: String] = [:]
}

/// 回放引擎(值类型,一次回放一个实例)。
struct ReplayEngine {
    var translator: MessageTranslator
    var forwardSubagentText: Bool
    private(set) var output = ReplayOutput()

    init(translator: MessageTranslator, forwardSubagentText: Bool) {
        self.translator = translator
        self.forwardSubagentText = forwardSubagentText
    }

    /// 翻译整段历史。
    /// - Parameter messages: `TranscriptStore.messages` 的结果
    /// - Returns: 更新列表与映射
    mutating func run(_ messages: [JSONValue]) -> ReplayOutput {
        for message in messages { replay(message) }
        return output
    }

    private mutating func replay(_ message: JSONValue) {
        if ReplayText.isReplayHiddenMeta(message) { return }
        let type = message["type"]?.stringValue ?? ""
        if let uuid = message["uuid"]?.nonEmptyString, let messageId = MessageTranslator.messageId(message) {
            output.messageIdToUuid[messageId] = uuid
        }
        guard var inner = message["message"]?.objectValue else { return }
        if type == "assistant", ReplayText.isSyntheticLogin(message["message"]) { return }
        if message["isCompactSummary"]?.boolValue == true { return }
        var prepared = message
        if type == "user" {
            if ReplayText.isTaskNotificationRecord(message) { return }
            guard let content = inner["content"], let stripped = ReplayText.stripLocalCommandMetadata(content) else { return }
            inner["content"] = stripped
            if var object = prepared.objectValue {
                object["message"] = .object(inner)
                prepared = .object(object)
            }
        }
        if message["parent_tool_use_id"] == nil { prepared = Self.withNullParent(prepared) }
        output.updates += translator.translateMessage(prepared, forwardSubagentText: forwardSubagentText, replay: true)
    }

    private static func withNullParent(_ message: JSONValue) -> JSONValue {
        guard var object = message.objectValue else { return message }
        object["parent_tool_use_id"] = .null
        return .object(object)
    }
}
