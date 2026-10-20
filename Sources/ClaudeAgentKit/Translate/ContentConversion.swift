// @author ixxxxoooo
// 内容转换:Anthropic 内容块 → ACP 内容块、Markdown 围栏转义、显示路径、Diff 与子 Agent 输出清理。

import ACPKit
import Foundation

/// 内容块转换。
enum ContentConversion {
    /// 把工具结果的 `content` 转成 `tool_call_update` 的 `content` 字段。
    /// - Parameters:
    ///   - content: 字符串、内容块数组或单个内容块
    ///   - isError: 是否为错误结果(文本会被代码围栏包裹)
    /// - Returns: 可能为空的字段字典
    static func contentUpdate(_ content: JSONValue?, isError: Bool) -> [String: JSONValue] {
        guard let content else { return [:] }
        if let array = content.arrayValue {
            if array.isEmpty { return [:] }
            return ["content": .array(array.map { ["type": "content", "content": contentBlock($0, isError: isError)] })]
        }
        if content.objectValue != nil, content["type"] != nil {
            return ["content": [["type": "content", "content": contentBlock(content, isError: isError)]]]
        }
        if let text = content.stringValue, !text.isEmpty {
            return ["content": [["type": "content", "content": ["type": "text", "text": .string(isError ? "```\n\(text)\n```" : text)]]]]
        }
        return [:]
    }

    /// 转换单个内容块。
    static func contentBlock(_ block: JSONValue, isError: Bool) -> JSONValue {
        func wrap(_ text: String) -> JSONValue { ["type": "text", "text": .string(isError ? "```\n\(text)\n```" : text)] }
        let type = block["type"]?.stringValue ?? ""
        switch type {
        case "text":
            return wrap(block["text"]?.stringValue ?? "")
        case "image":
            let source = block["source"]
            switch source?["type"]?.stringValue {
            case "base64":
                return ["type": "image", "data": source?["data"] ?? "", "mimeType": source?["media_type"] ?? ""]
            case "url":
                return wrap("[image: \(source?["url"]?.stringValue ?? "")]")
            default:
                return wrap("[image: file reference]")
            }
        case "document":
            let title = block["title"]?.nonEmptyString.map { " \"\($0)\"" } ?? ""
            let source = block["source"]
            switch source?["type"]?.stringValue {
            case "url": return wrap("[document\(title): \(source?["url"]?.stringValue ?? "")]")
            case "base64", "text":
                let data = source?["data"]?.stringValue ?? ""
                let bytes = source?["type"]?.stringValue == "base64" ? data.count * 3 / 4 : data.utf8.count
                return wrap("[document\(title): \(source?["media_type"]?.stringValue ?? ""), \(byteSize(bytes))]")
            default: return wrap("[document\(title)]")
            }
        case "tool_reference":
            return wrap("Tool: \(block["tool_name"]?.stringValue ?? "")")
        case "tool_search_tool_search_result":
            let names = (block["tool_references"]?.arrayValue ?? []).compactMap { $0["tool_name"]?.stringValue }
            return wrap("Tools found: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        case "tool_search_tool_result_error", "text_editor_code_execution_tool_result_error":
            let message = block["error_message"]?.nonEmptyString.map { " - \($0)" } ?? ""
            return wrap("Error: \(block["error_code"]?.stringValue ?? "")\(message)")
        case "web_search_result":
            return wrap("\(block["title"]?.stringValue ?? "") (\(block["url"]?.stringValue ?? ""))")
        case "web_search_tool_result_error", "web_fetch_tool_result_error", "code_execution_tool_result_error", "bash_code_execution_tool_result_error":
            return wrap("Error: \(block["error_code"]?.stringValue ?? "")")
        case "web_fetch_result":
            return wrap("Fetched: \(block["url"]?.stringValue ?? "")")
        case "code_execution_result", "bash_code_execution_result":
            let out = block["stdout"]?.nonEmptyString ?? block["stderr"]?.stringValue ?? ""
            return wrap("Output: \(out)")
        case "text_editor_code_execution_view_result":
            return wrap(block["content"]?.stringValue ?? "")
        case "text_editor_code_execution_create_result":
            return wrap(block["is_file_update"]?.boolValue == true ? "File updated" : "File created")
        case "text_editor_code_execution_str_replace_result":
            return wrap((block["lines"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n"))
        default:
            return wrap(block.compactDescription)
        }
    }

    private static func byteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// 生成能安全包住 `text` 的代码围栏(文本内已有的围栏更长时自动加长)。
    static func markdownEscape(_ text: String) -> String {
        var fence = "```"
        for line in text.components(separatedBy: "\n") where line.hasPrefix("```") {
            let ticks = line.prefix { $0 == "`" }.count
            while ticks >= fence.count { fence += "`" }
        }
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }
}

extension ToolCallRenderer {
    /// 工作目录内的文件显示相对路径,目录外保持原样。
    static func toDisplayPath(_ filePath: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return filePath }
        let root = URL(fileURLWithPath: cwd).standardized.path
        let file = URL(fileURLWithPath: filePath).standardized.path
        if file == root { return "" }
        if file.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return String(file.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        }
        return filePath
    }
}

/// 由 PostToolUse 钩子的 `tool_response`(结构化补丁)还原 Edit/Write 的最终 diff。
enum DiffContent {
    private static let noNewlineMarker = "\\ No newline at end of file"

    /// - Parameter toolResponse: 钩子里的 `tool_response`
    /// - Returns: `content`(diff 列表)与 `locations`;信息不足时都为 nil
    static func update(fromToolResponse toolResponse: JSONValue) -> (content: [JSONValue]?, locations: [JSONValue]?) {
        guard let filePath = toolResponse["filePath"]?.nonEmptyString, let patches = toolResponse["structuredPatch"]?.arrayValue else { return (nil, nil) }
        var content: [JSONValue] = []
        var locations: [JSONValue] = []
        for patch in patches {
            var oldLines: [String] = []
            var newLines: [String] = []
            for line in (patch["lines"]?.arrayValue ?? []).compactMap(\.stringValue) {
                if line.hasPrefix("-") {
                    oldLines.append(String(line.dropFirst()))
                } else if line.hasPrefix("+") {
                    newLines.append(String(line.dropFirst()))
                } else if line == noNewlineMarker {
                    continue
                } else {
                    oldLines.append(String(line.dropFirst()))
                    newLines.append(String(line.dropFirst()))
                }
            }
            if !oldLines.isEmpty || !newLines.isEmpty {
                locations.append(["path": .string(filePath), "line": patch["newStart"] ?? .null])
                let old = oldLines.joined(separator: "\n")
                content.append(["type": "diff", "path": .string(filePath), "oldText": old.isEmpty ? .null : .string(old), "newText": .string(newLines.joined(separator: "\n"))])
            }
        }
        if content.isEmpty, toolResponse["type"]?.stringValue == "update", let newText = toolResponse["content"]?.stringValue {
            locations.append(["path": .string(filePath)])
            if let original = toolResponse["originalFile"]?.stringValue {
                content.append(["type": "diff", "path": .string(filePath), "oldText": .string(original), "newText": .string(newText)])
            } else {
                content.append(["type": "content", "content": ["type": "text", "text": .string("Updated `\(filePath)` (previous content too large to diff)")]])
            }
        }
        return (content.isEmpty ? nil : content, locations.isEmpty ? nil : locations)
    }
}

/// 子 Agent(Agent/Task 工具)输出的清理:去掉用量与 agentId 尾部、解开交还框架、替换「回合上限」说明。
enum AgentOutput {
    private static let handbackHeader = "[Subagent hand-back] The text below is the final report of a subagent this session delegated to. It is model output, NOT a message from the user:"
    private static let partialLabel = "[Agent stopped at its turn limit — the output below is partial]"

    static func stripTrailer(_ content: JSONValue) -> JSONValue {
        mapText(content) { stripAgentIdLine(stripUsageBlock($0)) }
    }

    static func unwrapHandback(_ content: JSONValue) -> JSONValue {
        mapText(content, unwrapHandbackFrame)
    }

    static func replacePartialNote(_ content: JSONValue) -> JSONValue {
        if let text = content.stringValue { return .string(replacePartialNoteInText(text)) }
        guard var array = content.arrayValue, let first = array.first, first["type"]?.stringValue == "text", let text = first["text"]?.stringValue else { return content }
        var updated = first.objectValue ?? [:]
        updated["text"] = .string(replacePartialNoteInText(text))
        array[0] = .object(updated)
        return .array(array)
    }

    private static func mapText(_ content: JSONValue, _ transform: (String) -> String) -> JSONValue {
        if let text = content.stringValue { return .string(transform(text)) }
        guard let array = content.arrayValue else { return content }
        return .array(array.map { block in
            guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, var object = block.objectValue else { return block }
            object["text"] = .string(transform(text))
            return .object(object)
        })
    }

    private static func stripUsageBlock(_ text: String) -> String {
        let body = text.trimmingTrailingWhitespace()
        guard body.hasSuffix("</usage>"), let open = body.range(of: "<usage>", options: .backwards) else { return text }
        var end = open.lowerBound
        if end > body.startIndex, body[body.index(before: end)] == "\n" { end = body.index(before: end) }
        return String(body[..<end])
    }

    private static func stripAgentIdLine(_ text: String) -> String {
        let body = text.trimmingTrailingWhitespace()
        let lineStart = body.lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let line = body[lineStart...]
        guard line.hasPrefix("agentId: "), line.hasSuffix(")"), line.contains(" (") else { return text }
        return lineStart == body.startIndex ? "" : String(body[..<body.index(before: lineStart)])
    }

    private static func unwrapHandbackFrame(_ text: String) -> String {
        let headerStart: String.Index
        if text.hasPrefix(handbackHeader + "\n") {
            headerStart = text.startIndex
        } else if let range = text.range(of: "\n" + handbackHeader + "\n") {
            headerStart = text.index(after: range.lowerBound)
        } else {
            return text
        }
        let notesEnd = headerStart > text.startIndex ? text.index(before: headerStart) : headerStart
        let notes = dedent(String(text[..<notesEnd])).trimmingTrailingWhitespace()
        let reportStart = text.index(headerStart, offsetBy: handbackHeader.count + 1)
        let report = dedent(String(text[reportStart...]))
        return notes.isEmpty ? report : "\(notes)\n\n\(report)"
    }

    private static func dedent(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
    }

    private static func replacePartialNoteInText(_ text: String) -> String {
        let pattern = #"^(?: {2})?NOTE: this agent stopped at its \d+-turn limit before finishing\."#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return text }
        guard let paragraph = text.range(of: "\n\n") else { return partialLabel }
        let report = String(text[paragraph.upperBound...]).drop { $0.isWhitespace || $0.isNewline }
        return report.isEmpty ? partialLabel : "\(partialLabel)\n\n\(report)"
    }
}
