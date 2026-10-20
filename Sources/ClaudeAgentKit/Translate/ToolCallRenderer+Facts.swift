// @author ixxxxoooo
// 工具渲染器的「按工具名」规则:标题/种类/展示内容(tool_use 侧)与结果内容(tool_result 侧)。

import ACPKit
import Foundation

/// Bash 类结果的内部承载键(`resultFacts` 返回的字典里携带命令输出,稍后转成终端事件或控制台文本)。
enum CommandResult {
    static let key = "__command"
}

extension ToolCallRenderer {
    // MARK: tool_use 侧

    /// 计算工具调用的标题、种类、展示内容与位置。
    /// - Parameters:
    ///   - name: 工具名
    ///   - input: 工具入参
    ///   - cwd: 工作目录
    static func facts(_ name: String, _ input: JSONValue, cwd: String?) -> ToolFacts {
        switch name {
        case "Agent", "Task":
            let effort = input["effort"]?.nonEmptyString.map { " (\($0) effort)" } ?? ""
            var facts = ToolFacts(title: (input["description"]?.nonEmptyString ?? "Task") + effort, kind: "think")
            if let prompt = input["prompt"]?.stringValue { facts.display = [textContent(prompt)] }
            return facts
        case "Bash", "PowerShell":
            var facts = ToolFacts(title: input["command"]?.nonEmptyString ?? "Terminal", kind: "execute", command: true)
            if let description = shellDescription(input) { facts.display = [textContent(description)] }
            return facts
        case "Read":
            let offset = input["offset"]?.intValue
            let limit = input["limit"]?.intValue
            var suffix = ""
            if let limit, limit > 0 {
                let start = offset ?? 1
                suffix = " (\(start) - \(start + limit - 1))"
            } else if let offset, offset != 0 {
                suffix = " (from line \(offset))"
            }
            let path = input["file_path"]?.nonEmptyString
            let display = path.map { toDisplayPath($0, cwd: cwd) } ?? "File"
            var facts = ToolFacts(title: "Read " + display + suffix, kind: "read")
            facts.locations = path.map { [["path": .string($0), "line": .int(offset ?? 1)]] } ?? []
            return facts
        case "Write":
            return writeFacts(input, cwd: cwd)
        case "Edit":
            let path = input["file_path"]?.nonEmptyString
            var facts = ToolFacts(title: path.map { "Edit " + toDisplayPath($0, cwd: cwd) } ?? "Edit", kind: "edit")
            facts.locations = path.map { [["path": .string($0)]] } ?? []
            let old = input["old_string"]?.stringValue ?? ""
            let new = input["new_string"]?.stringValue ?? ""
            if let path, !old.isEmpty || !new.isEmpty {
                facts.change = [["type": "diff", "path": .string(path), "oldText": old.isEmpty ? .null : .string(old), "newText": .string(new)]]
            }
            return facts
        case "NotebookEdit":
            return ToolFacts(title: "NotebookEdit", kind: "other")
        case "Glob":
            var label = "Find"
            let path = input["path"]?.nonEmptyString
            if let path { label += " `\(path)`" }
            if let pattern = input["pattern"]?.nonEmptyString { label += " `\(pattern)`" }
            var facts = ToolFacts(title: label, kind: "search")
            facts.locations = path.map { [["path": .string($0)]] } ?? []
            return facts
        case "Grep":
            return ToolFacts(title: grepLabel(input), kind: "search")
        case "WebFetch":
            let from = (input["offset"]?.intValue).flatMap { $0 != 0 ? " (from char \($0))" : nil } ?? ""
            var facts = ToolFacts(title: input["url"]?.nonEmptyString.map { "Fetch \($0)\(from)" } ?? "Fetch", kind: "fetch")
            if let prompt = input["prompt"]?.nonEmptyString { facts.display = [textContent(prompt)] }
            return facts
        case "WebSearch":
            return ToolFacts(title: input["query"]?.nonEmptyString.map { "Search \"\($0)\"" } ?? "Web search", kind: "fetch")
        case "TodoWrite":
            let todos = input["todos"]?.arrayValue
            let title = todos.map { "Update TODOs: " + $0.map { $0["content"]?.stringValue ?? "" }.joined(separator: ", ") } ?? "Update TODOs"
            return ToolFacts(title: title, kind: "think")
        case "TaskCreate":
            return ToolFacts(title: input["subject"]?.nonEmptyString.map { "Create task: \($0)" } ?? "Create task", kind: "think")
        case "TaskUpdate":
            return ToolFacts(title: input["subject"]?.nonEmptyString.map { "Update task: \($0)" } ?? "Update task", kind: "think")
        case "TaskList":
            return ToolFacts(title: "List tasks", kind: "think")
        case "TaskGet":
            return ToolFacts(title: "Get task", kind: "think")
        case "ReportFindings":
            let findings = input["findings"]?.arrayValue ?? []
            var facts = ToolFacts(
                title: findings.isEmpty ? "Report findings: none found" : "Report \(findings.count) finding\(findings.count == 1 ? "" : "s")",
                kind: "think"
            )
            facts.display = findings.map { finding in
                let line = finding["line"]?.intValue.map { ":\($0)" } ?? ""
                return textContent("**\(finding["file"]?.stringValue ?? "")\(line)** — \(finding["summary"]?.stringValue ?? "")")
            }
            return facts
        case "ExitPlanMode":
            var facts = ToolFacts(title: "Approve Plan", kind: "switch_mode")
            if let plan = input["plan"]?.nonEmptyString { facts.display = [textContent(plan)] }
            return facts
        case "AskUserQuestion":
            let questions = input["questions"]?.arrayValue ?? []
            var facts = ToolFacts(title: "Asking for your input", kind: "other")
            if questions.count == 1, let question = questions[0]["question"]?.nonEmptyString { facts.title = question }
            facts.display = questions.compactMap { $0["question"]?.stringValue }.map(textContent)
            return facts
        case "Skill":
            return ToolFacts(title: input["skill"]?.nonEmptyString.map { "Load skill: \($0)" } ?? "Load skill", kind: "other")
        default:
            return ToolFacts(title: name.isEmpty ? "Unknown Tool" : name, kind: "other")
        }
    }

    private static func writeFacts(_ input: JSONValue, cwd: String?) -> ToolFacts {
        let path = input["file_path"]?.nonEmptyString ?? input["path"]?.nonEmptyString
        let contentKey = ["content", "file_text", "file_content"].first { key in
            if let value = input[key], !value.isNull { return true }
            return false
        }
        let content = contentKey.flatMap { input[$0] }
        var facts = ToolFacts(title: path.map { "Write " + toDisplayPath($0, cwd: cwd) } ?? "Preparing file…", kind: "edit")
        facts.locations = path.map { [["path": .string($0)]] } ?? []
        if let path {
            facts.change = [["type": "diff", "path": .string(path), "oldText": .null, "newText": content ?? .null]]
        } else if let text = content?.stringValue, !text.isEmpty {
            facts.display = [textContent(text)]
        }
        return facts
    }

    private static func shellDescription(_ input: JSONValue) -> String? {
        input["description"]?.stringValue ?? input["command_description"]?.stringValue
    }

    private static func grepLabel(_ input: JSONValue) -> String {
        var label = "grep"
        if input["-i"]?.boolValue == true { label += " -i" }
        if input["-n"]?.boolValue == true { label += " -n" }
        for flag in ["-A", "-B", "-C"] {
            if let value = input[flag], !value.isNull { label += " \(flag) \(scalarText(value))" }
        }
        let mode = input["output_mode"]?.stringValue ?? (isTrue(input["-l"]) ? "files_with_matches" : isTrue(input["-c"]) ? "count" : nil)
        if mode == "files_with_matches" { label += " -l" } else if mode == "count" { label += " -c" }
        if let limit = input["head_limit"], !limit.isNull { label += " | head -\(scalarText(limit))" }
        if let glob = input["glob"]?.nonEmptyString { label += " --include=\"\(glob)\"" }
        if let type = input["type"]?.nonEmptyString { label += " --type=\(type)" }
        if input["multiline"]?.boolValue == true { label += " -P" }
        if let pattern = input["pattern"]?.nonEmptyString { label += " \"\(pattern)\"" }
        if let path = input["path"]?.stringValue ?? input["file_path"]?.stringValue, !path.isEmpty { label += " \(path)" }
        return label
    }

    private static func isTrue(_ value: JSONValue?) -> Bool {
        value?.boolValue == true || value?.stringValue == "true"
    }

    private static func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): return String(flag)
        default: return value.compactDescription
        }
    }

    // MARK: tool_result 侧

    /// 计算工具结果对应的更新字段(内容、标题、命令输出)。
    func resultFacts(_ toolUse: ToolUse, result: JSONValue, structured: JSONValue?) -> [String: JSONValue] {
        let content = result["content"]
        let isError = result["is_error"]?.boolValue == true
        let hasErrorText: Bool = {
            guard isError, let content else { return false }
            if let text = content.stringValue { return !text.isEmpty }
            if let array = content.arrayValue { return !array.isEmpty }
            return false
        }()
        let structuredObject = structured?.objectValue != nil ? structured : nil
        if hasErrorText {
            if ["Bash", "PowerShell"].contains(toolUse.name), capabilities.terminalOutput {
                return bashResult(result: result, structured: structuredObject)
            }
            return ContentConversion.contentUpdate(content, isError: true)
        }
        switch toolUse.name {
        case "Bash", "PowerShell":
            return bashResult(result: result, structured: structuredObject)
        case "Read":
            return readResult(toolUse, result: result, structured: structuredObject)
        case "Write", "Edit", "Skill":
            return [:]
        case "WebSearch":
            return webSearchResult(result: result, structured: structuredObject)
        case "Agent", "Task":
            return agentResult(result: result, structured: structuredObject)
        case "ExitPlanMode":
            return ["title": "Exited Plan Mode"]
        default:
            return ContentConversion.contentUpdate(content, isError: isError)
        }
    }

    private func bashResult(result: JSONValue, structured: JSONValue?) -> [String: JSONValue] {
        let content = result["content"]
        let isError = result["is_error"]?.boolValue == true
        var output = ""
        var exitCode: Int? = isError ? nil : 0
        var interrupted = false
        if let structured, let stdout = structured["stdout"]?.stringValue, let stderr = structured["stderr"]?.stringValue,
           structured["isImage"]?.boolValue != true, structured["backgroundTaskId"] == nil {
            output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            if structured["interrupted"]?.boolValue == true {
                output = [output, "[Command was aborted before completion]"].filter { !$0.isEmpty }.joined(separator: "\n")
                exitCode = nil
                interrupted = true
            }
            if structured["returnCodeInterpretation"] != nil { exitCode = nil }
            if let path = structured["persistedOutputPath"]?.stringValue {
                let size = structured["persistedOutputSize"]?.intValue.map { " (\($0) bytes total)" } ?? ""
                output = [output, "[Output truncated\(size): full output saved to \(path)]"].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        } else if let content, content["type"]?.stringValue == "bash_code_execution_result" {
            output = [content["stdout"]?.stringValue ?? "", content["stderr"]?.stringValue ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            exitCode = content["return_code"]?.intValue
        } else if let text = content?.stringValue {
            output = text
        } else if let array = content?.arrayValue, !array.isEmpty {
            let allText = array.allSatisfy { $0["text"]?.stringValue != nil }
            if !allText { return ContentConversion.contentUpdate(content, isError: isError) }
            output = array.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        }
        if isError, exitCode == nil { exitCode = Self.failureExitCode(output) }
        if structured?["backgroundTaskId"] != nil { exitCode = nil }
        var command: [String: JSONValue] = ["output": .string(output)]
        if let exitCode { command["exitCode"] = .int(exitCode) }
        if interrupted { command["interrupted"] = true }
        return [CommandResult.key: .object(command)]
    }

    private static func failureExitCode(_ text: String) -> Int? {
        guard text.hasPrefix("Exit code ") else { return nil }
        let rest = text.dropFirst("Exit code ".count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.isEmpty || after.first == "\n" else { return nil }
        return Int(digits)
    }

    private func readResult(_ toolUse: ToolUse, result: JSONValue, structured: JSONValue?) -> [String: JSONValue] {
        if let structured, structured["type"]?.stringValue == "text", let file = structured["file"], let text = file["content"]?.stringValue, !text.isEmpty {
            let startLine = file["startLine"]?.intValue ?? toolUse.input["offset"]?.intValue ?? 1
            var body = text
            if body.hasSuffix("\n") { body.removeLast() }
            var numbered = body.components(separatedBy: "\n").enumerated().map { "\(startLine + $0.offset)\t\($0.element)" }.joined(separator: "\n")
            if file["truncatedByTokenCap"]?.boolValue == true {
                var detail = ""
                if let shown = file["numLines"]?.intValue, let total = file["totalLines"]?.intValue { detail = ": showing \(shown) of \(total) lines" }
                numbered += "\n[File truncated\(detail)]"
            }
            return ["content": [Self.textContent(ContentConversion.markdownEscape(numbered))]]
        }
        let content = result["content"]
        if let array = content?.arrayValue, !array.isEmpty {
            return ["content": .array(array.map { block in
                let inner: JSONValue = block["type"]?.stringValue == "text"
                    ? ["type": "text", "text": .string(ContentConversion.markdownEscape(block["text"]?.stringValue ?? ""))]
                    : ContentConversion.contentBlock(block, isError: false)
                return ["type": "content", "content": inner]
            })]
        }
        if let text = content?.stringValue, !text.isEmpty {
            return ["content": [Self.textContent(ContentConversion.markdownEscape(text))]]
        }
        return [:]
    }

    private func webSearchResult(result: JSONValue, structured: JSONValue?) -> [String: JSONValue] {
        if let results = structured?["results"]?.arrayValue {
            var lines: [String] = []
            for entry in results {
                if let text = entry.stringValue { lines.append(text); continue }
                for hit in entry["content"]?.arrayValue ?? [] {
                    if let title = hit["title"]?.stringValue, let url = hit["url"]?.stringValue { lines.append("\(title) (\(url))") }
                }
            }
            if !lines.isEmpty { return ["content": [Self.textContent(lines.joined(separator: "\n"))]] }
        }
        return ContentConversion.contentUpdate(result["content"], isError: result["is_error"]?.boolValue == true)
    }

    private func agentResult(result: JSONValue, structured: JSONValue?) -> [String: JSONValue] {
        let isError = result["is_error"]?.boolValue == true
        if let structured, structured["status"]?.stringValue == "completed", let content = structured["content"]?.arrayValue, !content.isEmpty {
            return ContentConversion.contentUpdate(AgentOutput.replacePartialNote(.array(content)), isError: isError)
        }
        let content = result["content"].map { AgentOutput.unwrapHandback(AgentOutput.stripTrailer($0)) }
        return ContentConversion.contentUpdate(content.map(AgentOutput.replacePartialNote), isError: isError)
    }

    /// ExitPlanMode 被拒时,Claude 会把说明包在一层 Markdown 围栏里;只剥一层完整外围栏。
    static func exitPlanModeRawOutput(_ toolName: String, _ content: JSONValue?) -> JSONValue? {
        guard toolName == "ExitPlanMode", let text = content?.stringValue else { return content }
        let trimmedStart = text.drop { $0.isWhitespace }
        guard trimmedStart.hasPrefix("```") else { return content }
        let lines = trimmedStart.components(separatedBy: "\n")
        guard lines.count >= 3, lines.last.map({ $0.trimmingCharacters(in: .whitespaces) == "```" }) == true else { return content }
        return .string(lines.dropFirst().dropLast().joined(separator: "\n"))
    }
}
