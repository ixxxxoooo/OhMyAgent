// @author ixxxxoooo
// 工具调用的呈现模型:把 ACP 的 ToolCall 归纳为“动词 + 对象 + 附注”的一行摘要(Cursor 风格紧凑工具行),
// 并提供搜索结果解析与时间线步骤分组。纯数据逻辑,不含视图,便于单测。

import ACPKit
import DiffKit
import Foundation
import OMLog

/// 工具调用的一行摘要。
public struct ToolPresentation: Sendable, Equatable {
    /// 呈现类别(决定图标、展开内容与是否可归入“浏览”分组)。
    public enum Category: String, Sendable, Equatable, CaseIterable {
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
    /// 子 Agent 类型(仅 `.subagent`,来自 `subagent_type`,如 Explore、code-reviewer)。
    public var agentType: String?
    /// 对象是否为文件路径(视图据此显示文件图标并支持点击打开)。
    public var subjectIsPath: Bool

    /// 工具调用是否是子 Agent 启动工具(Claude Code 的 Task/Agent,OpenCode 的 task;名称不区分大小写)。
    /// - Parameter tool: 工具调用
    public static func isSubagentLaunch(_ tool: ToolCall) -> Bool {
        guard let name = tool.name?.lowercased() else { return false }
        return name == "task" || name == "agent"
    }

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
        self.agentType = nil
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
        if hasChild || Self.isSubagentLaunch(tool) {
            category = .subagent
            verb = String(localized: "子任务")
            subject = input?["description"]?.stringValue ?? tool.title
            agentType = input?["subagent_type"]?.stringValue
            if input?["run_in_background"]?.boolValue == true { detail = String(localized: "后台") }
            return
        }
        if name == "TodoWrite" || name == "ExitPlanMode" {
            category = .plan
            verb = name == "ExitPlanMode" ? String(localized: "提交计划") : String(localized: "更新待办")
            subject = ""
            return
        }

        switch tool.kind {
        case .read:
            category = .read
            verb = String(localized: "读取")
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
            detail = Self.lineRange(input: input, location: tool.locations.first)
        case .edit:
            let isNew = name == "Write" || Self.createToolNames.contains(name.lowercased()) || tool.content.contains {
                if case .diff(_, let old, _) = $0 { return old == nil }
                return false
            }
            category = isNew ? .write : .edit
            verb = isNew ? String(localized: "写入") : String(localized: "编辑")
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
            detail = Self.lineRange(input: input, location: tool.locations.first)
        case .delete:
            category = .delete
            verb = String(localized: "删除")
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
        case .move:
            category = .move
            verb = String(localized: "移动")
            subject = path ?? Self.stripVerb(tool.title)
            subjectIsPath = path != nil
        case .search:
            category = .search
            let pattern = input?["pattern"]?.stringValue ?? input?["query"]?.stringValue
            verb = name == "Glob" || name.lowercased() == "find_by_name" ? String(localized: "查找文件") : String(localized: "搜索")
            subject = pattern ?? Self.stripVerb(tool.title)
            detail = input?["path"]?.stringValue.map { ($0 as NSString).lastPathComponent }
                ?? input?["glob"]?.stringValue
        case .execute:
            category = .terminal
            verb = String(localized: "运行")
            let command = input?["command"]?.stringValue ?? Self.stripVerb(tool.title)
            subject = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
            detail = input?["description"]?.stringValue
        case .fetch:
            category = .fetch
            verb = name == "WebSearch" || name.lowercased() == "search_web" ? String(localized: "联网搜索") : String(localized: "获取")
            subject = input?["url"]?.stringValue ?? input?["query"]?.stringValue ?? Self.stripVerb(tool.title)
        case .think:
            category = .think
            verb = String(localized: "思考")
            subject = tool.title
        case .switchMode:
            category = .other
            verb = String(localized: "切换模式")
            subject = tool.title
        case .other:
            category = .other
            verb = ""
            subject = tool.title.isEmpty ? (tool.name ?? String(localized: "工具调用")) : Self.prettyTitle(tool.title)
        }
    }

    /// 「新建文件」类工具名(小写):其 Diff 没有旧内容时也据此归为「写入」。
    static let createToolNames: Set<String> = ["write_to_file", "client_create_file", "create_file"]

    /// 美化只有工具标识的标题:`Running manage_task` → `manage task`;其余原样返回。
    static func prettyTitle(_ title: String) -> String {
        guard let name = ToolInputNormalizer.toolName(fromTitle: title) else { return title }
        return name.replacingOccurrences(of: "_", with: " ")
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
        for prefix in ["读取 ", "修改 ", "编辑 ", "写入 ", "运行 ", "搜索 ", "Read ", "Edit ", "Write ", "Running ", "Run "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    /// 读取/编辑范围:支持 StartLine/EndLine、start_line/end_line、offset/limit、行号等。
    static func lineRange(input: JSONValue?, location: ToolLocation?) -> String? {
        let start = input?["StartLine"]?.intValue
            ?? input?["start_line"]?.intValue
            ?? input?["first_line"]?.intValue
            ?? input?["Start"]?.intValue
            ?? input?["start"]?.intValue
            ?? input?["offset"]?.intValue
        let end = input?["EndLine"]?.intValue
            ?? input?["end_line"]?.intValue
            ?? input?["last_line"]?.intValue
            ?? input?["End"]?.intValue
            ?? input?["end"]?.intValue
        let limit = input?["limit"]?.intValue

        if let start, let end {
            return "L\(start)-\(end)"
        }
        if let start, let limit {
            return "L\(start)-\(start + limit - 1)"
        }
        if let start {
            return String(localized: "L\(start)起")
        }
        if let end {
            return String(localized: "至 L\(end)")
        }
        if let limit {
            return String(localized: "前 \(limit) 行")
        }
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
        if found { return (added, removed) }

        // 回退:从 rawInput 中解析改动统计 (Edit / Write / replace_file_content)
        if let input = tool.rawInput {
            let oldText = input["old_string"]?.stringValue ?? input["oldText"]?.stringValue ?? input["TargetContent"]?.stringValue
            let newText = input["new_string"]?.stringValue ?? input["newText"]?.stringValue ?? input["ReplacementContent"]?.stringValue
                ?? input["CodeContent"]?.stringValue ?? input["content"]?.stringValue
            if let newText {
                let diff = LineDiff.diff(old: oldText, new: newText)
                if diff.added > 0 || diff.removed > 0 {
                    return (diff.added, diff.removed)
                }
            }
        }
        return nil
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

    /// 结构签名:身份与成员数量。行内容由条目自身的可观察状态驱动,
    /// 所以只要签名不变,行视图就无需因父视图重新求值而重建(配合 `Equatable` 视图使用)。
    @MainActor
    public var signature: Int {
        switch self {
        case .entry(let entry): return entry.id.hashValue
        case .explore(let group):
            var hasher = Hasher()
            hasher.combine(group.id)
            hasher.combine(group.entries.count)
            return hasher.finalize()
        }
    }
}

/// 把条目序列分组的结果缓存:`revision` 与条目数都没变时直接复用,避免输入区等无关状态变化时重复分组。
@MainActor
public final class TimelineItemsCache {
    private var owner: ObjectIdentifier?
    private var revision = -1
    private var count = -1
    private var density: ToolDensity = .standard
    private var items: [TimelineItem] = []

    public init() {}

    /// 取分组结果。
    /// - Parameters:
    ///   - store: 时间线
    ///   - density: 工具调用详细程度
    /// - Returns: 展示单元序列
    public func items(for store: TimelineStore, density: ToolDensity = .standard) -> [TimelineItem] {
        if owner == ObjectIdentifier(store), store.structureRevision == revision, store.entries.count == count, self.density == density { return items }
        let span = Log.perf.span("时间线分组", warnMs: 8, quiet: true, ["entries": "\(store.entries.count)"])
        items = TimelineGrouping.group(store.entries, density: density)
        span.end()
        self.density = density
        owner = ObjectIdentifier(store)
        revision = store.structureRevision
        count = store.entries.count
        return items
    }
}

/// 浏览步骤分组。
@MainActor
public struct ExploreGroup: Identifiable {
    /// 分组风格:`explore` 只含浏览类步骤;`activity` 是精简档下合并的全部工具活动。
    public enum Style: Sendable { case explore, activity }

    public let id: UUID
    public let entries: [TimelineEntry]
    public let style: Style

    /// - Parameters:
    ///   - id: 分组 ID(取首个成员的 ID)
    ///   - entries: 成员条目(含其间的思考)
    ///   - style: 分组风格,默认浏览
    public init(id: UUID, entries: [TimelineEntry], style: Style = .explore) {
        self.id = id
        self.entries = entries
        self.style = style
    }

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

    /// 摘要:浏览风格如“已浏览 3 个文件、2 次搜索”;活动风格如“编辑了 2 个文件、运行了 2 条命令”。
    public var summary: String {
        style == .activity ? activitySummary : exploreSummary
    }

    /// 活动摘要(精简档):按类别计数,顺序固定(编辑 → 新建 → 删除/移动 → 运行 → 读取 → 搜索 → 联网 → MCP)。
    var activitySummary: String {
        var edits = 0, writes = 0, removes = 0, runs = 0, reads = 0, searches = 0, fetches = 0, mcps = 0, others = 0
        for entry in entries {
            guard let tool = entry.tool else { continue }
            switch ToolPresentation(tool: tool).category {
            case .edit: edits += 1
            case .write: writes += 1
            case .delete, .move: removes += 1
            case .terminal:
                // 与 Claude Code 一致:grep/rg/find 算「搜索」,cat/ls/head 算「读取」,其余才是「运行命令」
                switch ShellIntent.classify(ToolPresentation(tool: tool).subject) {
                case .search: searches += 1
                case .read: reads += 1
                case .run: runs += 1
                }
            case .read: reads += 1
            case .search: searches += 1
            case .fetch: fetches += 1
            case .mcp: mcps += 1
            default: others += 1
            }
        }
        var parts: [String] = []
        if edits > 0 { parts.append(isRunning ? String(localized: "编辑 \(edits) 个文件") : String(localized: "编辑了 \(edits) 个文件")) }
        if writes > 0 { parts.append(isRunning ? String(localized: "新建 \(writes) 个文件") : String(localized: "新建了 \(writes) 个文件")) }
        if removes > 0 { parts.append(isRunning ? String(localized: "删除/移动 \(removes) 个文件") : String(localized: "删除/移动了 \(removes) 个文件")) }
        if runs > 0 { parts.append(isRunning ? String(localized: "运行 \(runs) 条命令") : String(localized: "运行了 \(runs) 条命令")) }
        if reads > 0 { parts.append(isRunning ? String(localized: "读取 \(reads) 个文件") : String(localized: "读取了 \(reads) 个文件")) }
        if searches > 0 { parts.append(isRunning ? String(localized: "搜索 \(searches) 次") : String(localized: "搜索了 \(searches) 次")) }
        if fetches > 0 { parts.append(isRunning ? String(localized: "联网 \(fetches) 次") : String(localized: "联网了 \(fetches) 次")) }
        if mcps > 0 { parts.append(isRunning ? String(localized: "调用 \(mcps) 个 MCP 工具") : String(localized: "调用了 \(mcps) 个 MCP 工具")) }
        if others > 0 { parts.append(isRunning ? String(localized: "执行 \(others) 个其他工具") : String(localized: "执行了 \(others) 个其他工具")) }
        return parts.joined(separator: String(localized: "、"))
    }

    var exploreSummary: String {
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
        if reads > 0 { parts.append(String(localized: "\(reads) 个文件")) }
        if searches > 0 { parts.append(String(localized: "\(searches) 次搜索")) }
        if fetches > 0 { parts.append(String(localized: "\(fetches) 次联网")) }
        return (isRunning ? String(localized: "正在浏览 ") : String(localized: "已浏览 ")) + parts.joined(separator: String(localized: "、"))
    }
}

/// 时间线分组器。
public enum TimelineGrouping {
    /// 把连续 ≥2 个可合并的工具(及其间的思考)合并为一组,其余条目保持原样。
    /// 标准/详细档只合并“浏览”类(读取/搜索/联网);精简档合并全部普通工具(子 Agent、计划与等待授权的工具除外)。
    /// - Parameters:
    ///   - entries: 时间线条目
    ///   - density: 工具调用详细程度,默认标准
    /// - Returns: 展示单元序列
    @MainActor
    public static func group(_ entries: [TimelineEntry], density: ToolDensity = .standard) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var run: [TimelineEntry] = []
        let style: ExploreGroup.Style = density == .compact ? .activity : .explore

        func isExploreTool(_ entry: TimelineEntry) -> Bool {
            guard entry.kind == .tool, let tool = entry.tool else { return false }
            let presentation = ToolPresentation(tool: tool, hasChild: entry.childStore != nil)
            if density != .compact { return presentation.isExploration }
            // 精简档:等待授权/子 Agent/计划/思考类工具保持独立可见
            if tool.status == .pending || entry.childStore != nil { return false }
            return ![.subagent, .plan, .think].contains(presentation.category)
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
            // 精简档对齐 Claude Code:单个命令/搜索/读取也折叠成「运行了 1 条命令」这样的摘要行(编辑、新建等仍单独展示)
            let tools = members.filter { $0.kind == .tool }
            let soloCollapses = density == .compact && tools.count == 1 && tools[0].tool.map {
                [.terminal, .search, .read, .fetch].contains(ToolPresentation(tool: $0).category)
            } == true
            if tools.count >= 2 || soloCollapses {
                items.append(.explore(ExploreGroup(id: members[0].id, entries: members, style: style)))
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


/// Shell 命令的意图(用于精简档摘要:搜索 / 读取 / 其他命令)。
enum ShellIntent: Sendable, Equatable {
    case search, read, run

    private static let searchTools: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "find", "fd", "locate"]
    private static let readTools: Set<String> = ["cat", "head", "tail", "ls", "less", "more", "wc", "stat", "file", "tree", "bat", "nl", "du", "pwd"]

    /// 判断一条命令的意图:拆开 `&&`/`;`/`|` 后忽略 `cd`/环境变量赋值/`rtk` 前缀,
    /// 所有有效片段都同属搜索(或读取)才归为搜索(或读取),否则是运行命令。
    /// - Parameter command: 命令文本(取首行即可)
    /// - Returns: 意图
    static func classify(_ command: String) -> ShellIntent {
        let segments = command
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .split(separator: ";")
        var intents: [ShellIntent] = []
        for segment in segments {
            // 管道只看第一个命令(`grep x | head` 仍是搜索)
            let head = segment.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            var words = head.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, first.contains("=") && !first.hasPrefix("-") || first == "rtk" || first == "command" { words.removeFirst() }
            guard let tool = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if tool == "cd" || tool == "export" || tool == "set" { continue }
            if searchTools.contains(tool) { intents.append(.search) }
            else if readTools.contains(tool) { intents.append(.read) }
            else { return .run }
        }
        guard let first = intents.first, intents.allSatisfy({ $0 == first }) else { return .run }
        return first
    }
}
