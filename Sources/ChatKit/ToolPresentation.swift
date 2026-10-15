// @author ygw
// 工具调用的呈现模型:把 ACP 的 ToolCall 归纳为“动词 + 对象 + 附注”的一行摘要(Cursor 风格紧凑工具行),
// 并提供搜索结果解析与时间线步骤分组。纯数据逻辑,不含视图,便于单测。

import ACPKit
import DiffKit
import Foundation

/// 工具调用的一行摘要。
public struct ToolPresentation: Sendable, Equatable {
    /// 呈现类别(决定图标、展开内容与是否可归入“浏览”分组)。
    public enum Category: String, Sendable, Equatable {
        case read, write, edit, delete, move, search, terminal, fetch, mcp, subagent, plan, think, other
    }

    public var category: Category
    /// 动词,如“读取”“编辑”“运行”。
    public var verb: String
    /// 对象:文件路径、命令、搜索词、URL……
    public var subject: String
    /// 附注,如行范围 `L10-60`、搜索目录、命令说明。
    public var detail: String?
    /// MCP 服务器名(仅 `.mcp`)。
    public var mcpServer: String?
    /// 对象是否为文件路径(视图据此显示文件图标并支持点击打开)。
    public var subjectIsPath: Bool

    /// 由工具调用推导呈现信息。
    /// - Parameters:
    ///   - tool: 工具调用
    ///   - hasChild: 是否派生了子 Agent 时间线
    public init(tool: ToolCall, hasChild: Bool = false) {
        let input = tool.rawInput
        let name = tool.name ?? ""
        let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue
            ?? input?["notebook_path"]?.stringValue ?? tool.locations.first?.path
        self.mcpServer = nil
        self.detail = nil
        self.subjectIsPath = false

        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
            // mcp__server__tool:server / tool 本身可含单下划线,按双下划线切分
            let segments = name.components(separatedBy: "__")
            category = .mcp
            mcpServer = segments.count > 1 ? segments[1] : parts.dropFirst().first
            verb = segments.count > 2 ? segments[2...].joined(separator: "__") : name
            subject = input.map(Self.briefInput) ?? ""
            return
        }
        if hasChild || name == "Task" || name == "Agent" {
            category = .subagent
            verb = "子任务"
            subject = input?["description"]?.stringValue ?? tool.title
            return
        }
        if name == "TodoWrite" || name == "ExitPlanMode" {
            category = .plan
            verb = name == "ExitPlanMode" ? "提交计划" : "更新待办"
            subject = ""
            return
        }

        switch tool.kind {
        case .read:
            category = .read
            verb = "读取"
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
            detail = Self.lineRange(input: input, location: tool.locations.first)
        case .edit:
            let isNew = name == "Write" || tool.content.contains {
                if case .diff(_, let old, _) = $0 { return old == nil }
                return false
            }
            category = isNew ? .write : .edit
            verb = isNew ? "写入" : "编辑"
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
        case .delete:
            category = .delete
            verb = "删除"
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
        case .move:
            category = .move
            verb = "移动"
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
        case .search:
            category = .search
            let pattern = input?["pattern"]?.stringValue ?? input?["query"]?.stringValue
            verb = name == "Glob" ? "查找文件" : "搜索"
            subject = pattern ?? Self.stripVerb(tool.title)
            detail = input?["path"]?.stringValue.map { ($0 as NSString).lastPathComponent }
                ?? input?["glob"]?.stringValue
        case .execute:
            category = .terminal
            verb = "运行"
            let command = input?["command"]?.stringValue ?? Self.stripVerb(tool.title)
            subject = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
            detail = input?["description"]?.stringValue
        case .fetch:
            category = .fetch
            verb = name == "WebSearch" ? "联网搜索" : "获取"
            subject = input?["url"]?.stringValue ?? input?["query"]?.stringValue ?? Self.stripVerb(tool.title)
        case .think:
            category = .think
            verb = "思考"
            subject = tool.title
        case .switchMode:
            category = .other
            verb = "切换模式"
            subject = tool.title
        case .other:
            category = .other
            verb = ""
            subject = tool.title.isEmpty ? (tool.name ?? "工具调用") : tool.title
        }
    }

    /// 是否属于“浏览”类(读取/搜索/联网获取),可被折叠为分组。
    public var isExploration: Bool {
        category == .read || category == .search || category == .fetch
    }

    /// 完整的单行文本(无障碍与测试使用)。
    public var plainText: String {
        [verb, subject, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: 辅助

    /// 去掉标题里常见的动词前缀(“读取 ”“修改 ”等),避免与动词重复。
    static func stripVerb(_ title: String) -> String {
        for prefix in ["读取 ", "修改 ", "编辑 ", "写入 ", "运行 ", "搜索 ", "Read ", "Edit ", "Write ", "Run "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    /// 读取范围:优先 offset/limit,其次位置行号。
    static func lineRange(input: JSONValue?, location: ToolLocation?) -> String? {
        if let offset = input?["offset"]?.intValue {
            if let limit = input?["limit"]?.intValue { return "L\(offset)-\(offset + limit - 1)" }
            return "L\(offset)起"
        }
        if let limit = input?["limit"]?.intValue { return "前 \(limit) 行" }
        if let line = location?.line, line > 0 { return "L\(line)" }
        return nil
    }

    /// MCP 入参的简短描述:取第一个标量值。
    static func briefInput(_ input: JSONValue) -> String {
        guard let object = input.objectValue else { return "" }
        for key in object.keys.sorted() {
            if let value = object[key]?.stringValue, !value.isEmpty { return "\(key): \(value)" }
        }
        return ""
    }

    /// 汇总工具产生的 Diff 统计(新增/删除行数)。
    /// - Parameter tool: 工具调用
    /// - Returns: 无 Diff 内容时返回 nil;超大文本使用近似统计避免卡顿
    public static func diffStats(of tool: ToolCall) -> (added: Int, removed: Int)? {
        var added = 0, removed = 0, found = false
        for content in tool.content {
            guard case .diff(_, let old, let new) = content else { continue }
            found = true
            if old == nil {
                added += lineCount(new)
            } else if lineCount(new) + lineCount(old ?? "") > 4000 {
                added += lineCount(new)
                removed += lineCount(old ?? "")
            } else {
                let diff = LineDiff.diff(old: old, new: new)
                added += diff.added
                removed += diff.removed
            }
        }
        return found ? (added, removed) : nil
    }

    static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? count - 1 : count
    }
}

// MARK: - 搜索结果解析

/// 搜索结果中的一条命中。
public struct SearchHit: Sendable, Equatable, Identifiable {
    public var id: Int
    public var path: String
    public var line: Int?
    public var text: String?
}

/// 把 Grep/Glob 的文本输出解析为可点击的结果列表。
public enum SearchResultParser {
    /// 解析结果。
    /// - Parameters:
    ///   - output: 工具输出文本
    ///   - limit: 最多返回条数
    /// - Returns: 命中列表(无法识别的行被忽略)
    public static func parse(_ output: String, limit: Int = 200) -> [SearchHit] {
        var hits: [SearchHit] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if hits.count >= limit { break }
            if let hit = parseLine(line, id: hits.count) { hits.append(hit) }
        }
        return hits
    }

    private static func parseLine(_ line: String, id: Int) -> SearchHit? {
        // path:line:text 或 path:line-text(rg/grep -n)
        if let match = line.firstMatch(of: /^(.+?):(\d+)[:-](.*)$/), looksLikePath(String(match.1)) {
            return SearchHit(id: id, path: String(match.1), line: Int(match.2), text: String(match.3).trimmingCharacters(in: .whitespaces))
        }
        // 纯路径(files_with_matches / Glob)
        if looksLikePath(line) { return SearchHit(id: id, path: line, line: nil, text: nil) }
        return nil
    }

    private static func looksLikePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.count < 400, !value.contains(" matches") else { return false }
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") { return true }
        // 相对路径:含 / 且无空白,或带常见扩展名
        if value.contains(" ") { return false }
        return value.contains("/") || value.contains(".")
    }
}

// MARK: - 时间线分组

/// 对话流中的展示单元。
@MainActor
public enum TimelineItem: Identifiable {
    /// 单个条目。
    case entry(TimelineEntry)
    /// 一组连续的“浏览”步骤(读取/搜索/联网获取及其间的思考)。
    case explore(ExploreGroup)

    public nonisolated var id: UUID {
        switch self {
        case .entry(let entry): return entry.id
        case .explore(let group): return group.id
        }
    }
}

/// 浏览步骤分组。
@MainActor
public struct ExploreGroup: Identifiable {
    public let id: UUID
    public let entries: [TimelineEntry]

    /// 工具条目数量。
    public var toolCount: Int { entries.filter { $0.kind == .tool }.count }

    /// 是否仍在进行(有工具未结束或思考仍在流式)。
    public var isRunning: Bool {
        entries.contains { entry in
            if entry.kind == .tool { return !(entry.tool?.status.isTerminal ?? true) }
            return entry.isStreaming
        }
    }

    /// 是否有失败步骤。
    public var hasFailure: Bool { entries.contains { $0.tool?.status == .failed } }

    /// 摘要,如“已浏览 3 个文件、2 次搜索”。
    public var summary: String {
        var reads = 0, searches = 0, fetches = 0
        for entry in entries {
            guard let tool = entry.tool else { continue }
            switch ToolPresentation(tool: tool).category {
            case .read: reads += 1
            case .search: searches += 1
            case .fetch: fetches += 1
            default: break
            }
        }
        var parts: [String] = []
        if reads > 0 { parts.append("\(reads) 个文件") }
        if searches > 0 { parts.append("\(searches) 次搜索") }
        if fetches > 0 { parts.append("\(fetches) 次联网") }
        return (isRunning ? "正在浏览 " : "已浏览 ") + parts.joined(separator: "、")
    }
}

/// 时间线分组器。
public enum TimelineGrouping {
    /// 把连续 ≥2 个“浏览”工具(及其间的思考)合并为一组,其余条目保持原样。
    /// - Parameter entries: 时间线条目
    /// - Returns: 展示单元序列
    @MainActor
    public static func group(_ entries: [TimelineEntry]) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var run: [TimelineEntry] = []

        func isExploreTool(_ entry: TimelineEntry) -> Bool {
            guard entry.kind == .tool, let tool = entry.tool else { return false }
            return ToolPresentation(tool: tool, hasChild: entry.childStore != nil).isExploration
        }
        /// 结束当前连续段:尾部的思考不并入分组。
        func flush() {
            var members = run
            var trailing: [TimelineEntry] = []
            while let last = members.last, last.kind == .thought {
                trailing.insert(members.removeLast(), at: 0)
            }
            while let first = members.first, first.kind == .thought {
                items.append(.entry(members.removeFirst()))
            }
            if members.filter({ $0.kind == .tool }).count >= 2 {
                items.append(.explore(ExploreGroup(id: members[0].id, entries: members)))
            } else {
                items.append(contentsOf: members.map(TimelineItem.entry))
            }
            items.append(contentsOf: trailing.map(TimelineItem.entry))
            run.removeAll()
        }

        for entry in entries {
            if entry.kind == .thought || isExploreTool(entry) {
                run.append(entry)
            } else {
                flush()
                items.append(.entry(entry))
            }
        }
        flush()
        return items
    }
}
