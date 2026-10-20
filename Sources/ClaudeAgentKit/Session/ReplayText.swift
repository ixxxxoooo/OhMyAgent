// @author ixxxxoooo
// 转录文本清洗:去掉 CLI 写进用户消息里的本地命令/系统提示标记,识别任务通知,判断合成登录消息。

import ACPKit
import Foundation

/// 转录文本处理。
enum ReplayText {
    /// 本地斜杠命令只在转录里留下标记,回放时不展示。
    static let hiddenCommands: Set<String> = ["/context", "/heapdump", "/extra-usage", "/compact", "/model", "/mcp", "/status", "/usage"]
    /// 仅由 CLI 本地处理、不调用模型的命令。
    static let localOnlyCommands: Set<String> = ["/context", "/heapdump", "/extra-usage"]
    static let markerTags = ["command-name", "command-message", "command-args", "local-command-stdout", "local-command-stderr", "system-reminder", "task-notification"]

    /// 单遍扫描去掉每个 `<tag>…</tag>`(匹配最近的同名闭合标签);没有闭合标签的开标签原样保留。
    static func stripMarkerTags(_ text: String) -> String {
        var dead = Set<String>()
        var result = ""
        var copiedUpTo = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<" {
                var matched = false
                for tag in markerTags where !dead.contains(tag) {
                    let open = "<\(tag)>"
                    guard text[index...].hasPrefix(open) else { continue }
                    let close = "</\(tag)>"
                    if let end = text.range(of: close, range: text.index(index, offsetBy: open.count)..<text.endIndex) {
                        result += text[copiedUpTo..<index]
                        index = end.upperBound
                        copiedUpTo = index
                        matched = true
                    } else {
                        dead.insert(tag)
                    }
                    break
                }
                if matched { continue }
            }
            index = text.index(after: index)
        }
        return result + text[copiedUpTo...]
    }

    /// 取 `<tag>…</tag>` 之间的文本。
    static func markerTagText(_ text: String, _ tag: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// 只含标记的文本:还原为用户当时输入的斜杠命令(隐藏命令返回 nil)。
    private static func commandInvocation(_ text: String) -> String? {
        if markerTagText(text, "local-command-stdout") != nil || markerTagText(text, "local-command-stderr") != nil { return nil }
        guard let name = markerTagText(text, "command-name")?.trimmingCharacters(in: .whitespaces), name.hasPrefix("/") else { return nil }
        if hiddenCommands.contains(String(name.split(separator: " ").first ?? "")) { return nil }
        let args = markerTagText(text, "command-args")?.trimmingCharacters(in: .whitespaces) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    private static func stripText(_ text: String) -> String? {
        let stripped = stripMarkerTags(text)
        if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stripped }
        return commandInvocation(text)
    }

    /// 清洗用户消息内容。
    /// - Returns: 清洗后的内容;全部为元数据时返回 nil
    static func stripLocalCommandMetadata(_ content: JSONValue) -> JSONValue? {
        if let text = content.stringValue { return stripText(text).map(JSONValue.string) }
        guard let blocks = content.arrayValue else { return content }
        var kept: [JSONValue] = []
        for block in blocks {
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
                guard let stripped = stripText(text) else { continue }
                var object = block.objectValue ?? [:]
                object["text"] = .string(stripped)
                kept.append(.object(object))
            } else {
                kept.append(block)
            }
        }
        return kept.isEmpty ? nil : .array(kept)
    }

    /// 内容是否纯属本地命令元数据。
    static func isLocalCommandMetadata(_ content: JSONValue) -> Bool {
        stripLocalCommandMetadata(content) == nil
    }

    /// 是否为 CLI 合成的「请登录」助手消息。
    static func isSyntheticLogin(_ apiMessage: JSONValue?) -> Bool {
        guard apiMessage?["model"]?.stringValue == "<synthetic>", let content = apiMessage?["content"]?.arrayValue, content.count == 1,
              content[0]["type"]?.stringValue == "text", let text = content[0]["text"]?.stringValue else { return false }
        return text.contains("Please run /login")
    }

    /// 回放时隐藏的元消息来源。
    static let hiddenMetaOrigins: Set<String> = ["peer", "channel", "observer", "observer-activity", "slack-ping"]

    /// 是否为回放时应隐藏的元消息。
    static func isReplayHiddenMeta(_ message: JSONValue) -> Bool {
        guard message["type"]?.stringValue == "user", message["isMeta"]?.boolValue == true || message["is_meta"]?.boolValue == true,
              let kind = message.at("origin", "kind")?.stringValue else { return false }
        return hiddenMetaOrigins.contains(kind)
    }

    /// 是否为任务通知记录(自治任务回报,不是用户发言)。
    static func isTaskNotificationRecord(_ message: JSONValue) -> Bool {
        message.at("origin", "kind")?.stringValue == "task-notification" && message.at("origin", "subkind") == nil
    }

    /// 助手消息中的纯文本(拼接所有 text 块)。
    static func assistantText(_ apiMessage: JSONValue?) -> String? {
        guard let content = apiMessage?["content"] else { return nil }
        if let text = content.stringValue { return text }
        let parts = (content.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
