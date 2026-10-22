// @author ixxxxoooo
// 补全引擎:`/` 斜杠命令与 `@` 文件提及。解析触发上下文、模糊匹配打分、后台文件索引。

import ACPKit
import Foundation

/// 补全触发类型。
public enum CompletionTrigger: Sendable, Equatable {
    case slash
    case mention
}

/// 触发上下文:要被替换的范围与查询词。
public struct CompletionContext: Sendable, Equatable {
    public var trigger: CompletionTrigger
    /// 需要被替换的 UTF-16 范围(含触发字符)
    public var range: NSRange
    /// 触发字符之后的查询词
    public var query: String
}

/// 补全候选项。
public struct CompletionItem: Identifiable, Sendable, Hashable {
    /// 候选类别(决定图标与排序分组)。
    public enum Kind: Sendable, Hashable {
        /// 分组标题(补全菜单分节用)。
        public var groupTitle: String {
            switch self {
            case .localCommand: return ChatL10n.t("客户端命令")
            case .agentCommand: return ChatL10n.t("Agent 命令")
            case .customCommand: return ChatL10n.t("自定义命令")
            case .skill: return "Skills"
            case .mcpPrompt: return "MCP"
            case .subagent: return ChatL10n.t("子 Agent")
            case .browser: return ChatL10n.t("工具")
            case .file: return ChatL10n.t("文件")
            case .folder: return ChatL10n.t("文件夹")
            }
        }

        /// Agent 通告的内置命令(/compact、/init……)
        case agentCommand
        /// 客户端接管的命令(/config、/agents……)
        case localCommand
        case file
        /// 文件夹(`@目录/`)
        case folder
        /// Skill(含插件内的 Skill)
        case skill
        /// 用户/项目/插件的自定义斜杠命令
        case customCommand
        /// MCP 服务器提供的提示(`/mcp__服务器__提示`)
        case mcpPrompt
        /// `@agent-名称` 子 Agent 提及
        case subagent
        /// `@browser`:让 Agent 用内置浏览器做这件事
        case browser
    }
    public var id: String { "\(kind)-\(insertText)" }
    /// 菜单分组标题。
    public var groupTitle: String { kind.groupTitle }
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// 接受后替换到文本中的内容
    public var insertText: String
    /// 来源徽标(如「Skill」「项目」「插件 foo」「MCP」「内置」)
    public var badge: String?

    public init(kind: Kind, title: String, subtitle: String? = nil, insertText: String, badge: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.insertText = insertText
        self.badge = badge
    }
}

/// 来自本机 Claude 配置的斜杠条目(Skill 或自定义命令),用于给 Agent 通告的命令标注来源,
/// 以及在 Agent 尚未通告时(连接前)直接提供候选。
public struct SlashEntry: Sendable, Hashable {
    public var name: String
    public var summary: String
    public var hint: String?
    public var badge: String
    public var kind: CompletionItem.Kind

    public init(name: String, summary: String, hint: String? = nil, badge: String, kind: CompletionItem.Kind) {
        self.name = name
        self.summary = summary
        self.hint = hint
        self.badge = badge
        self.kind = kind
    }
}

/// 模糊匹配打分:子序列匹配,前缀、词边界、连续命中加分,间隔扣分。
public enum FuzzyMatcher {
    /// - Parameters:
    ///   - query: 查询词(大小写不敏感)
    ///   - candidate: 候选文本
    /// - Returns: 分数(越高越好);不匹配返回 nil
    public static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        var score = 0
        var qi = 0
        var lastMatch = -2
        for (ci, char) in c.enumerated() where qi < q.count && char == q[qi] {
            var gain = 1
            if ci == 0 { gain += 8 }
            if ci > 0, "/_-. ".contains(original[ci - 1]) { gain += 5 }
            if ci > 0, original[ci - 1].isLowercase, original[ci].isUppercase { gain += 4 }
            if ci == lastMatch + 1 { gain += 4 } else if lastMatch >= 0 { gain -= min(3, ci - lastMatch - 1) }
            score += gain
            lastMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        // 越短越相关
        return score * 4 - min(c.count, 200) / 8
    }
}

/// 补全引擎(纯函数部分)。
public enum CompletionEngine {
    /// 客户端接管的命令候选(由 `LocalCommands.catalog` 生成)。
    public static let localCommands: [CompletionItem] = LocalCommands.catalog.map { spec in
        CompletionItem(kind: .localCommand, title: "/\(spec.name)" + (spec.hint.map { " <\($0)>" } ?? ""),
                       subtitle: spec.summary, insertText: "/\(spec.name)", badge: ChatL10n.t("客户端"))
    }

    /// 解析光标处的补全上下文。
    /// - Parameters:
    ///   - text: 输入框全文
    ///   - cursor: 光标位置(UTF-16 偏移)
    /// - Returns: 上下文;不在补全场景时为 nil
    public static func context(text: String, cursor: Int) -> CompletionContext? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let before = ns.substring(to: cursor)

        // 斜杠命令:只在整条消息开头,且命令词内没有空白
        if before.hasPrefix("/"), !before.dropFirst().contains(where: { $0.isWhitespace }) {
            return CompletionContext(trigger: .slash, range: NSRange(location: 0, length: cursor), query: String(before.dropFirst()))
        }

        // @ 提及:最近的 @ 位于开头或空白之后,且其后到光标没有空白
        guard let atIndex = before.lastIndex(of: "@") else { return nil }
        let prefix = before[..<atIndex]
        if let last = prefix.last, !last.isWhitespace { return nil }
        let query = before[before.index(after: atIndex)...]
        if query.contains(where: { $0.isWhitespace }) { return nil }
        let location = (String(prefix) as NSString).length
        return CompletionContext(trigger: .mention, range: NSRange(location: location, length: cursor - location), query: String(query))
    }

    /// 斜杠命令候选:客户端命令 + Agent 通告的命令(按本机配置标注来源)。
    /// - Parameters:
    ///   - query: 查询词(不含 `/`)
    ///   - agentCommands: Agent 通告的命令
    ///   - entries: 本机 Skills/自定义命令;用于标注来源,Agent 尚未通告任何命令时也直接作为候选
    ///   - limit: 最大数量(默认足够容纳全部命令:弹层可滚动,不能在空查询时截掉内置命令)
    public static func slashItems(query: String, agentCommands: [AvailableCommand], entries: [SlashEntry] = [], limit: Int = 300) -> [CompletionItem] {
        var items = localCommands
        let known = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set(items.map(\.insertText))
        for command in agentCommands where !seen.contains("/\(command.name)")
            && !command.name.hasPrefix("__") && !ClaudeBuiltinCommands.hiddenFromCompletion.contains(command.name) {
            seen.insert("/\(command.name)")
            let hint = (command.inputHint ?? known[command.name]?.hint).map { " <\($0)>" } ?? ""
            let summary = command.description.isEmpty ? (known[command.name]?.summary ?? "") : command.description
            let kind: CompletionItem.Kind
            let badge: String
            if let entry = known[command.name] {
                kind = entry.kind
                badge = entry.badge
            } else if command.name.hasPrefix("mcp__") {
                kind = .mcpPrompt
                badge = "MCP"
            } else {
                kind = .agentCommand
                badge = ChatL10n.t("内置")
            }
            items.append(CompletionItem(kind: kind, title: "/\(command.name)\(hint)", subtitle: summary, insertText: "/\(command.name)", badge: badge))
        }
        // Agent 还没通告命令(连接中/失败)时,用本机配置与 Claude Code 内置清单兜底,
        // 让 Skills、自定义命令与内置命令在连接前也能选择;连接后以适配器通告为准
        if agentCommands.isEmpty {
            items += ClaudeBuiltinCommands.items(excluding: Set(seen.map { String($0.dropFirst()) }))
            seen.formUnion(ClaudeBuiltinCommands.catalog.map { "/\($0.name)" })
            for entry in entries where !seen.contains("/\(entry.name)") {
                seen.insert("/\(entry.name)")
                items.append(CompletionItem(kind: entry.kind, title: "/\(entry.name)" + (entry.hint.map { " <\($0)>" } ?? ""),
                                            subtitle: entry.summary, insertText: "/\(entry.name)", badge: entry.badge))
            }
        }
        // 同分时:客户端命令 → 自定义命令 → Claude 内置命令 → Skill → MCP 提示(内置命令比技能更常用,不能被排到后面)
        let order: [CompletionItem.Kind: Int] = [.localCommand: 0, .customCommand: 1, .agentCommand: 2, .skill: 3, .mcpPrompt: 4]
        let scored = items.enumerated().compactMap { index, item -> (CompletionItem, Int, Int)? in
            let name = String(item.insertText.dropFirst())
            guard let score = FuzzyMatcher.score(query: query, candidate: name) else { return nil }
            return (item, score, index)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let lo = order[lhs.0.kind] ?? 9, ro = order[rhs.0.kind] ?? 9
            return lo != ro ? lo < ro : lhs.2 < rhs.2
        }
        return sorted.prefix(limit).map(\.0)
    }

    /// 生成 `@路径` 插入文本:含空白时加引号,文件夹以 `/` 结尾,末尾带一个空格。
    /// - Parameters:
    ///   - path: 工作区相对路径
    ///   - isDirectory: 是否为文件夹
    public static func mentionInsertText(path: String, isDirectory: Bool) -> String {
        let text = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        return text.contains(where: { $0.isWhitespace }) ? "@\"\(text)\" " : "@\(text) "
    }

    /// `@agent-名称` 子 Agent 提及候选。
    /// - Parameters:
    ///   - query: `@` 之后的查询词
    ///   - agents: 可用子 Agent(名称、说明、来源徽标)
    ///   - limit: 最大数量
    public static func agentMentionItems(query: String, agents: [(name: String, summary: String, badge: String)], limit: Int = 6) -> [CompletionItem] {
        let q = query.lowercased()
        let scored = agents.compactMap { agent -> (CompletionItem, Int)? in
            let handle = "agent-\(agent.name)"
            // 查询词以 "agent-" 开头时按名称部分打分
            let needle = q.hasPrefix("agent-") ? String(q.dropFirst(6)) : q
            guard let score = needle.isEmpty ? 0 : FuzzyMatcher.score(query: needle, candidate: agent.name) else { return nil }
            return (CompletionItem(kind: .subagent, title: "@\(handle)", subtitle: agent.summary, insertText: "@\(handle) ", badge: agent.badge), score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// `@browser` 候选:查询词为空或与 browser 模糊匹配时出现。
    /// - Parameter query: `@` 后的查询词
    public static func browserMentionItems(query: String) -> [CompletionItem] {
        guard query.isEmpty || FuzzyMatcher.score(query: query.lowercased(), candidate: BrowserMention.handle) != nil else { return [] }
        return [CompletionItem(kind: .browser, title: "@\(BrowserMention.handle)", subtitle: ChatL10n.t("用内置浏览器测试页面、截图、看日志"),
                               insertText: "@\(BrowserMention.handle) ", badge: ChatL10n.t("浏览器"))]
    }

    /// 去掉编辑器引用产生的行号后缀:`a/b.swift:12` 或 `a/b.swift:12-20`;
    /// 若带后缀的整体恰好是存在的文件名则保持原样。
    /// - Parameters:
    ///   - path: `@` 后面的路径(可能带行号后缀)
    ///   - workspace: 工作区目录
    /// - Returns: 不含行号后缀的路径
    public static func stripLineSuffix(_ path: String, workspace: URL) -> String {
        guard let colon = path.lastIndex(of: ":") else { return path }
        let suffix = path[path.index(after: colon)...]
        let numbers = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return path }
        let full = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: full.path) { return path }
        return String(path[..<colon])
    }

    /// 提取文本中的 `@路径` 令牌:`@` 必须位于开头或空白之后;支持 `@"含 空白 的路径"`。
    /// - Parameter text: 用户输入
    /// - Returns: `@` 之后的路径文本(按出现顺序,未去重)
    public static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let atStart = index == 0 || chars[index - 1].isWhitespace
            guard chars[index] == "@", atStart else { index += 1; continue }
            var cursor = index + 1
            if cursor < chars.count, chars[cursor] == "\"" {
                // 带引号:读到下一个引号;没有闭合则忽略
                cursor += 1
                let begin = cursor
                while cursor < chars.count, chars[cursor] != "\"" { cursor += 1 }
                if cursor < chars.count {
                    tokens.append(String(chars[begin..<cursor]))
                    cursor += 1
                }
            } else {
                let begin = cursor
                while cursor < chars.count, !chars[cursor].isWhitespace { cursor += 1 }
                if cursor > begin { tokens.append(String(chars[begin..<cursor])) }
            }
            index = max(cursor, index + 1)
        }
        return tokens
    }

    /// 文本中的 `@路径` 提及,解析为真实存在的文件(可选包含文件夹)。
    /// - Parameters:
    ///   - text: 用户输入
    ///   - workspace: 工作区目录
    ///   - includeDirectories: 为 true 时文件夹提及也返回
    /// - Returns: 去重后的 URL 列表(按出现顺序)
    public static func mentionedFiles(in text: String, workspace: URL, includeDirectories: Bool = false) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        let quoted = Set(quotedTokens(in: text))
        for token in mentionTokens(in: text) {
            var path = token
            if !quoted.contains(token) {
                while let last = path.last, ",.;:!?)）。，；：！？".contains(last), !FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path) {
                    path.removeLast()
                }
            }
            guard !path.isEmpty else { continue }
            path = stripLineSuffix(path, workspace: workspace)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue, !includeDirectories { continue }
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
        }
        return result
    }

    /// 带引号的 `@"…"` 令牌集合(这类路径不做末尾标点裁剪)。
    private static func quotedTokens(in text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "@\"") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            result.append(String(after[..<end]))
            rest = after[after.index(after: end)...]
        }
        return result
    }
}

/// 工作区文件索引:后台枚举一次,之后查询只在内存中打分。
public actor FileIndex {
    private var paths: [String] = []
    private var directories: [String] = []
    private var root: URL?
    private var extraRoots: [URL] = []
    private var building: Task<Void, Never>?

    /// 默认忽略的目录名。
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv", "__pycache__",
        "dist", ".next", ".gradle", ".idea", ".swiftpm", "target", "Carthage",
    ]
    static let maxFiles = 60_000

    public init() {}

    /// 为工作区建立索引(幂等;根目录或附加文件夹变化时重建)。
    /// 附加文件夹(多文件夹工作区)里的文件与文件夹以绝对路径收录,主目录的仍为相对路径。
    /// - Parameters:
    ///   - root: 工作区主目录
    ///   - extraRoots: 附加文件夹
    public func prepare(root: URL, extraRoots: [URL] = []) {
        if self.root == root, self.extraRoots == extraRoots, building != nil { return }
        self.root = root
        self.extraRoots = extraRoots
        paths = []
        directories = []
        building = Task.detached(priority: .utility) { [weak self] in
            var found = Self.enumerateAll(root: root)
            for extra in extraRoots {
                let prefix = extra.standardizedFileURL.path + "/"
                let more = Self.enumerateAll(root: extra)
                found.files += more.files.map { prefix + $0 }
                found.directories += more.directories.map { prefix + $0 }
            }
            await self?.finish(found.files, directories: found.directories, for: root)
        }
    }

    /// 强制重建。
    public func invalidate() {
        building?.cancel()
        building = nil
        if let root { prepare(root: root, extraRoots: extraRoots) }
    }

    private func finish(_ found: [String], directories dirs: [String], for root: URL) {
        guard self.root == root else { return }
        paths = found
        directories = dirs
    }

    /// 等待索引完成(测试与首次查询使用)。
    public func waitUntilReady() async {
        await building?.value
    }

    /// 查询。
    /// - Parameters:
    ///   - query: 查询词(为空时返回浅层文件)
    ///   - limit: 数量上限
    /// - Returns: 相对路径,按相关度排序
    public func search(_ query: String, limit: Int = 30) -> [String] {
        if query.isEmpty {
            return paths.sorted { ($0.filter { $0 == "/" }.count, $0) < ($1.filter { $0 == "/" }.count, $1) }.prefix(limit).map { $0 }
        }
        var scored: [(String, Int)] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            // 文件名命中权重更高
            if let nameScore = FuzzyMatcher.score(query: query, candidate: name) {
                scored.append((path, nameScore + 40))
            } else if let pathScore = FuzzyMatcher.score(query: query, candidate: path) {
                scored.append((path, pathScore))
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    /// 查询文件夹(相对路径,不带结尾斜杠)。
    /// - Parameters:
    ///   - query: 查询词(为空时返回最浅层的文件夹)
    ///   - limit: 数量上限
    public func searchDirectories(_ query: String, limit: Int = 8) -> [String] {
        if query.isEmpty {
            return directories.sorted { ($0.filter { $0 == "/" }.count, $0) < ($1.filter { $0 == "/" }.count, $1) }.prefix(limit).map { $0 }
        }
        var scored: [(String, Int)] = []
        for path in directories {
            let name = (path as NSString).lastPathComponent
            if let nameScore = FuzzyMatcher.score(query: query, candidate: name) {
                scored.append((path, nameScore + 40))
            } else if let pathScore = FuzzyMatcher.score(query: query, candidate: path) {
                scored.append((path, pathScore))
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    /// 同步枚举(在后台线程调用);只返回文件。
    nonisolated static func enumerate(root: URL) -> [String] { enumerateAll(root: root).files }

    /// 同步枚举文件与文件夹(在后台线程调用)。
    nonisolated static func enumerateAll(root: URL) -> (files: [String], directories: [String]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var files: [String] = []
        var dirs: [String] = []
        let rootPath = root.standardizedFileURL.path
        let userIgnore = IndexIgnore.current(root: rootPath)
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : nil
            if values?.isDirectory == true {
                if ignoredDirectories.contains(name) || (relative.map { userIgnore.ignores(relativePath: $0, isDirectory: true) } ?? false) {
                    enumerator.skipDescendants()
                } else if let relative, dirs.count < maxFiles / 4 {
                    dirs.append(relative)
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let relative, !userIgnore.ignores(relativePath: relative, isDirectory: false) { files.append(relative) }
            if files.count >= maxFiles { break }
        }
        return (files, dirs)
    }
}
