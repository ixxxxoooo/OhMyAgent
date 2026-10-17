// @author ixxxxoooo
// 工作区文件能力(无视图):目录列举、文件索引、模糊匹配(快速打开)、全局文本搜索。

import ChatKit
import Foundation

/// 资源管理器中的一个条目。
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
}

/// 忽略规则:索引与搜索跳过的目录;资源管理器仅隐藏最少的内容。
public enum WorkspaceIgnore {
    /// 索引/搜索跳过的目录名。
    public static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "DerivedData", ".swiftpm", "Pods", ".idea", ".venv", "venv", "__pycache__", ".gradle", "target", ".next",
    ]
    /// 资源管理器隐藏的名称。
    public static let hiddenInExplorer: Set<String> = [".git", ".DS_Store"]
}

/// 文件索引与目录列举。
public enum WorkspaceFiles {
    /// 列出目录的直接子项:目录在前,按名称不区分大小写排序。
    /// - Parameter directory: 目录绝对路径
    /// - Returns: 条目;目录不存在返回空
    public static func list(directory: String) -> [FileEntry] {
        guard !directory.isEmpty else { return [] }
        let url = URL(fileURLWithPath: directory)
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
        let entries = items.compactMap { item -> FileEntry? in
            let name = item.lastPathComponent
            guard !WorkspaceIgnore.hiddenInExplorer.contains(name) else { return nil }
            let isDir = (try? item.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            return FileEntry(path: item.path, name: name, isDirectory: isDir)
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 递归索引工作区内的文件(相对路径),跳过忽略目录与符号链接目录。
    /// - Parameters:
    ///   - root: 工作区根目录
    ///   - limit: 最多返回的文件数
    ///   - ignore: 用户自定义忽略规则(默认读取设置)
    /// - Returns: 相对路径数组(已排序)
    public static func index(root: String, limit: Int = 100_000, ignore: IndexIgnore = .current()) -> [String] {
        guard !root.isEmpty, let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var result: [String] = []
        // 使用路径式枚举器直接得到相对路径,避免 /private 等符号链接前缀差异
        while let rel = enumerator.nextObject() as? String {
            if Task.isCancelled { break }
            let name = (rel as NSString).lastPathComponent
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory || type == .typeSymbolicLink {
                if type == .typeSymbolicLink || WorkspaceIgnore.skippedDirectories.contains(name)
                    || ignore.ignores(relativePath: rel, isDirectory: true) { enumerator.skipDescendants() }
                continue
            }
            guard type == .typeRegular, name != ".DS_Store", !ignore.ignores(relativePath: rel, isDirectory: false) else { continue }
            result.append(rel)
            if result.count >= limit { break }
        }
        return result.sorted()
    }
}

/// 模糊匹配结果。
public struct FuzzyMatch: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let score: Int
    /// 命中的字符位置(以 `path` 的 Character 下标)
    public let positions: [Int]
}

/// 快速打开的模糊匹配。
public enum FuzzyMatcher {
    /// 对路径做子序列匹配并打分:连续、词首、文件名内命中加分,路径越短越好。
    /// - Parameters:
    ///   - query: 查询(忽略大小写与空白)
    ///   - path: 候选路径
    /// - Returns: 无法匹配返回 nil
    public static func match(query: String, path: String) -> FuzzyMatch? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return FuzzyMatch(path: path, score: -path.count, positions: []) }
        let chars = Array(path)
        let lower = chars.map { Character($0.lowercased()) }
        let nameStart = (chars.lastIndex(of: "/") ?? -1) + 1
        var positions: [Int] = []
        var score = 0
        var qi = 0
        var last = -2
        for (i, c) in lower.enumerated() where qi < q.count && c == q[qi] {
            positions.append(i)
            if i == last + 1 { score += 8 }
            if i == 0 || "/_-. ".contains(chars[i - 1]) { score += 10 }
            else if chars[i].isUppercase, i > 0, chars[i - 1].isLowercase { score += 8 }
            if i >= nameStart { score += 4 }
            score += 1
            last = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // 文件名完整包含查询时大幅加分
        if String(lower[nameStart...]).contains(String(q)) { score += 30 }
        score -= chars.count / 8
        return FuzzyMatch(path: path, score: score, positions: positions)
    }

    /// 过滤并按得分排序。
    /// - Parameters:
    ///   - query: 查询
    ///   - paths: 候选集合
    ///   - limit: 返回上限
    public static func rank(query: String, in paths: [String], limit: Int = 50) -> [FuzzyMatch] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return paths.prefix(limit).map { FuzzyMatch(path: $0, score: 0, positions: []) }
        }
        let matches = paths.compactMap { match(query: query, path: $0) }
        return Array(matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }.prefix(limit))
    }
}

// MARK: - 全局文本搜索

/// 搜索选项。
public struct SearchOptions: Equatable, Sendable {
    public var query: String
    public var caseSensitive = false
    public var wholeWord = false
    public var isRegex = false
    /// 仅搜索路径包含该子串的文件(为空不限制)
    public var pathFilter = ""

    public init(query: String, caseSensitive: Bool = false, wholeWord: Bool = false, isRegex: Bool = false, pathFilter: String = "") {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.pathFilter = pathFilter
    }
}

/// 一处命中。
public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { "\(path):\(line):\(column)" }
    public let path: String
    /// 行号(1 起)
    public let line: Int
    /// 列(UTF-16,0 起)与长度,便于高亮
    public let column: Int
    public let length: Int
    /// 命中行预览(已截断)
    public let preview: String
    /// 预览中命中的起点(UTF-16)
    public let previewColumn: Int
}

/// 一个文件的命中集合。
public struct SearchFileResult: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let hits: [SearchHit]
}

/// 搜索输出。
public struct SearchOutput: Sendable {
    public var files: [SearchFileResult]
    public var totalHits: Int
    public var truncated: Bool
    /// 正则非法等错误
    public var error: String?
}

public enum WorkspaceSearch {
    static let maxFileBytes = 2_000_000
    static let maxHits = 3_000

    /// 编译搜索表达式。
    /// - Throws: 正则非法时抛出
    static func makeRegex(_ options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.isRegex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    /// 在工作区内搜索文本。逐文件并发,可取消。
    /// - Parameters:
    ///   - root: 工作区根目录
    ///   - options: 搜索选项
    ///   - files: 已有的相对路径索引(为空则现场建立)
    public static func search(root: String, options: SearchOptions, files: [String]? = nil) async -> SearchOutput {
        guard !options.query.isEmpty else { return SearchOutput(files: [], totalHits: 0, truncated: false, error: nil) }
        let regex: NSRegularExpression
        do { regex = try makeRegex(options) }
        catch { return SearchOutput(files: [], totalHits: 0, truncated: false, error: error.localizedDescription) }
        let paths = files ?? WorkspaceFiles.index(root: root)
        let filter = options.pathFilter.lowercased()
        let candidates = filter.isEmpty ? paths : paths.filter { $0.lowercased().contains(filter) }
        let rootPath = root.hasSuffix("/") ? root : root + "/"

        let results: [SearchFileResult] = await withTaskGroup(of: SearchFileResult?.self) { group in
            var iterator = candidates.makeIterator()
            var running = 0
            var collected: [SearchFileResult] = []
            var total = 0
            func next(_ group: inout TaskGroup<SearchFileResult?>) -> Bool {
                guard let rel = iterator.next() else { return false }
                group.addTask { searchFile(path: rootPath + rel, relative: rel, regex: regex) }
                return true
            }
            while running < 8, next(&group) { running += 1 }
            while let item = await group.next() {
                running -= 1
                if let item { collected.append(item); total += item.hits.count }
                if Task.isCancelled || total >= maxHits { group.cancelAll(); break }
                if next(&group) { running += 1 }
            }
            return collected
        }
        let sorted = results.sorted { $0.path < $1.path }
        var total = 0
        var limited: [SearchFileResult] = []
        for file in sorted {
            if total >= maxHits { break }
            let room = maxHits - total
            let hits = Array(file.hits.prefix(room))
            total += hits.count
            limited.append(SearchFileResult(path: file.path, hits: hits))
        }
        return SearchOutput(files: limited, totalHits: total, truncated: results.reduce(0) { $0 + $1.hits.count } > total || total >= maxHits, error: nil)
    }

    /// 搜索单个文件;二进制与超大文件返回 nil。
    static func searchFile(path: String, relative: String, regex: NSRegularExpression) -> SearchFileResult? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= maxFileBytes else { return nil }
        if data.prefix(8_192).contains(0) { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var hits: [SearchHit] = []
        var lineNumber = 0
        text.enumerateLines { line, stop in
            lineNumber += 1
            if Task.isCancelled { stop = true; return }
            let ns = line as NSString
            guard ns.length <= 2_000 else { return }
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                // 预览:去掉前导空白并限制长度,保证命中仍在预览内
                let lead = ns.length - (line.drop(while: { $0 == " " || $0 == "\t" }) as Substring).utf16.count
                let start = max(lead, m.range.location - 40)
                let end = min(ns.length, m.range.location + m.range.length + 120)
                let preview = ns.substring(with: NSRange(location: start, length: end - start))
                hits.append(SearchHit(path: relative, line: lineNumber, column: m.range.location, length: m.range.length, preview: preview, previewColumn: m.range.location - start))
                if hits.count >= 200 { break }
            }
        }
        return hits.isEmpty ? nil : SearchFileResult(path: relative, hits: hits)
    }
}
