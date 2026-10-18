// @author ixxxxoooo
// 计划文件(对标 Cursor 的 *.plan.md):YAML 头(name / overview / todos)+ Markdown 正文。
// 纯逻辑:从 Agent 给出的计划 Markdown 解析标题、概述与待办,生成文件名与文件内容,
// 并负责读写 `~/.claude/plans`(全局)与 `<项目>/.oma/plans`(保存到工作区)。无视图。

import Foundation

/// 计划里的一条待办。
public struct PlanTodo: Sendable, Equatable, Identifiable {
    /// 稳定标识(序号)
    public let id: String
    /// 待办内容
    public var content: String
    /// 状态:pending / in_progress / completed
    public var status: String

    public init(id: String, content: String, status: String = "pending") {
        self.id = id
        self.content = content
        self.status = status
    }
}

/// 一份计划。
public struct PlanDocument: Sendable, Equatable {
    /// 标题(取首个标题行,否则取首行文字)
    public var name: String
    /// 概述(标题之后的第一段文字)
    public var overview: String
    /// 待办列表
    public var todos: [PlanTodo]
    /// Markdown 正文(不含 YAML 头)
    public var body: String

    public init(name: String, overview: String, todos: [PlanTodo], body: String) {
        self.name = name
        self.overview = overview
        self.todos = todos
        self.body = body
    }

    /// 待办里已完成的数量。
    public var completedCount: Int { todos.filter { $0.status == "completed" }.count }

    // MARK: 解析

    /// 从计划 Markdown 解析(带或不带 YAML 头都可以)。
    /// - Parameter markdown: 计划文本
    /// - Returns: 计划;文本为空时标题回退为「计划」
    public static func parse(markdown: String) -> PlanDocument {
        let (frontmatter, savedTodos, body) = splitFrontmatter(markdown)
        let lines = body.components(separatedBy: "\n")
        let name = frontmatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? title(in: lines)
        let overview = frontmatter["overview"].flatMap { $0.isEmpty ? nil : $0 } ?? firstParagraph(in: lines)
        return PlanDocument(name: name, overview: overview, todos: savedTodos.isEmpty ? todos(in: lines) : savedTodos,
                            body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 拆出 YAML 头(单行标量与 `todos` 列表)与正文。
    private static func splitFrontmatter(_ text: String) -> ([String: String], [PlanTodo], String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return ([:], [], text) }
        let lines = trimmed.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], [], text) }
        var values: [String: String] = [:]
        var todos: [PlanTodo] = []
        for line in lines[1..<end] {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("- id:") {
                todos.append(PlanTodo(id: scalar(stripped, after: "- id:"), content: "", status: "pending"))
            } else if stripped.hasPrefix("content:"), !todos.isEmpty, line.hasPrefix(" ") {
                todos[todos.count - 1].content = scalar(stripped, after: "content:")
            } else if stripped.hasPrefix("status:"), !todos.isEmpty, line.hasPrefix(" ") {
                todos[todos.count - 1].status = scalar(stripped, after: "status:")
            } else if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") {
                values[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = scalar(line, after: String(line[...colon]))
            }
        }
        return (values, todos.filter { !$0.content.isEmpty }, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// 取 `前缀` 之后的标量值,去掉首尾引号并还原转义。
    private static func scalar(_ line: String, after prefix: String) -> String {
        var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
            value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    private static func title(in lines: [String]) -> String {
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") { return text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        }
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? String(localized: "计划") : String(first.prefix(60))
    }

    private static func firstParagraph(in lines: [String]) -> String {
        var paragraph: [String] = []
        var seenTitle = false
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") { if !seenTitle { seenTitle = true; continue } else if !paragraph.isEmpty { break } else { continue } }
            if text.isEmpty { if !paragraph.isEmpty { break } else { continue } }
            if text.hasPrefix("-") || text.hasPrefix("*") || text.hasPrefix(">") || text.first?.isNumber == true || text.hasPrefix("```") { if paragraph.isEmpty { continue } else { break } }
            paragraph.append(text)
        }
        return String(paragraph.joined(separator: " ").prefix(200))
    }

    /// 待办的来源:优先 `- [ ]` 复选项;没有则取「步骤/任务/待办…」标题下的编号列表;再没有取全文的编号列表。
    private static func todos(in lines: [String]) -> [PlanTodo] {
        var checks: [PlanTodo] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            for (prefix, status) in [("- [ ] ", "pending"), ("* [ ] ", "pending"), ("- [x] ", "completed"), ("- [X] ", "completed"), ("* [x] ", "completed")] where text.hasPrefix(prefix) {
                checks.append(PlanTodo(id: "t\(checks.count + 1)", content: String(text.dropFirst(prefix.count)), status: status))
            }
        }
        if !checks.isEmpty { return Array(checks.prefix(30)) }
        let keywords = ["步骤", "任务", "待办", "实施", "实现", "计划", "step", "task", "todo", "implementation", "plan"]
        var inSection = false
        var sectioned: [PlanTodo] = []
        var all: [PlanTodo] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                let heading = text.lowercased()
                inSection = keywords.contains { heading.contains($0) }
                continue
            }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let content = numberedItem(text) else { continue }
            let todo = PlanTodo(id: "t\(all.count + 1)", content: content)
            all.append(todo)
            if inSection { sectioned.append(PlanTodo(id: "t\(sectioned.count + 1)", content: content)) }
        }
        return Array((sectioned.isEmpty ? all : sectioned).prefix(30))
    }

    /// 取编号列表项(`1. xxx` / `1) xxx`)的内容。
    private static func numberedItem(_ text: String) -> String? {
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = text.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let content = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    // MARK: 文件名与内容

    /// 文件名:`<标题 slug>_<6 位内容哈希>.plan.md`(同一份内容总是同一个名字)。
    public var fileName: String { Self.slug(name) + "_" + Self.shortHash(body) + ".plan.md" }

    /// 完整文件内容:YAML 头 + 正文。
    public func fileContents() -> String {
        var head = ["---", "name: \(Self.quote(name))", "overview: \(Self.quote(overview))", "todos:"]
        if todos.isEmpty { head[head.count - 1] = "todos: []" }
        for todo in todos {
            head.append("  - id: \(todo.id)")
            head.append("    content: \(Self.quote(todo.content))")
            head.append("    status: \(todo.status)")
        }
        head.append("---")
        return head.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// 标题转文件名片段:保留字母、数字与汉字,其余折成连字符,最长 40 个字符。
    static func slug(_ title: String) -> String {
        var out = ""
        var lastDash = true
        for character in title.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "plan" : trimmed
    }

    /// 6 位十六进制哈希(FNV-1a)。
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(String(hash, radix: 16).prefix(6)).padding(toLength: 6, withPad: "0", startingAt: 0)
    }
}

/// 计划文件的读写。
public enum PlanStore {
    /// 全局计划目录(`~/.claude/plans`);演示模式下主目录被重定向到沙盒。
    public static var globalDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/plans", isDirectory: true)
    }

    /// 工作区里的计划目录(`<项目>/.oma/plans`)。
    /// - Parameter workspace: 项目路径
    public static func workspaceDirectory(_ workspace: String) -> URL {
        URL(fileURLWithPath: workspace).appendingPathComponent(".oma/plans", isDirectory: true)
    }

    /// 把计划写入目录。
    /// - Parameters:
    ///   - document: 计划
    ///   - directory: 目标目录(不存在会创建)
    /// - Returns: 写入的文件地址
    @discardableResult
    public static func save(_ document: PlanDocument, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(document.fileName)
        try document.fileContents().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 读取计划文件。
    /// - Parameter url: 文件地址
    public static func read(_ url: URL) throws -> PlanDocument {
        PlanDocument.parse(markdown: try String(contentsOf: url, encoding: .utf8))
    }
}
