// @author ixxxxoooo
// 代码搜索(Bridge 工具 `search_code`):ChatKit 只定义请求/结果与格式化,真正的索引搜索由应用层注入
// (WorkbenchKit 的三元组索引,覆盖主目录与全部附加文件夹),与 Agent 自带的 grep 并存。

import ACPKit
import AgentHost
import Foundation
import Synchronization

/// 搜索请求。
public struct CodeSearchQuery: Sendable, Equatable {
    public var query: String
    public var isRegex = false
    public var caseSensitive = false
    public var wholeWord = false
    /// 仅搜索路径包含该子串的文件
    public var pathFilter = ""
    /// 返回的命中行数上限(1–200)
    public var maxResults = 50

    public init(query: String, isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false, pathFilter: String = "", maxResults: Int = 50) {
        self.query = query
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.pathFilter = pathFilter
        self.maxResults = min(max(maxResults, 1), 200)
    }

    /// 从 MCP 入参解析。
    /// - Parameter arguments: 工具入参
    /// - Returns: 请求;缺少 `query` 时为 nil
    public static func parse(_ arguments: JSONValue) -> CodeSearchQuery? {
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return CodeSearchQuery(query: query,
                               isRegex: arguments["regex"]?.boolValue ?? false,
                               caseSensitive: arguments["case_sensitive"]?.boolValue ?? false,
                               wholeWord: arguments["whole_word"]?.boolValue ?? false,
                               pathFilter: arguments["path"]?.stringValue ?? "",
                               maxResults: arguments["max_results"]?.intValue ?? 50)
    }
}

/// 一处命中。
public struct CodeSearchMatch: Sendable, Equatable {
    /// 所在文件夹(绝对路径)
    public var root: String
    /// 相对该文件夹的路径
    public var path: String
    public var line: Int
    public var preview: String

    public init(root: String, path: String, line: Int, preview: String) {
        self.root = root
        self.path = path
        self.line = line
        self.preview = preview
    }
}

/// 搜索结果。
public struct CodeSearchResult: Sendable, Equatable {
    public var matches: [CodeSearchMatch]
    public var totalHits: Int
    public var fileCount: Int
    public var truncated: Bool
    public var error: String?
    public var indexed: Bool
    public var scannedFiles: Int

    public init(matches: [CodeSearchMatch] = [], totalHits: Int = 0, fileCount: Int = 0, truncated: Bool = false, error: String? = nil, indexed: Bool = false, scannedFiles: Int = 0) {
        self.matches = matches
        self.totalHits = totalHits
        self.fileCount = fileCount
        self.truncated = truncated
        self.error = error
        self.indexed = indexed
        self.scannedFiles = scannedFiles
    }
}

/// 搜索实现的登记处(应用启动时注入)。
public final class CodeSearchProvider: Sendable {
    public static let shared = CodeSearchProvider()
    public typealias Handler = @Sendable (_ workspace: String, _ query: CodeSearchQuery) async -> CodeSearchResult
    private let handler = Mutex<Handler?>(nil)

    private init() {}

    /// 注入实现。
    /// - Parameter handler: 在工作区(含附加文件夹)内搜索
    public func install(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    /// 执行搜索;未注入实现时返回 nil。
    public func search(workspace: String, query: CodeSearchQuery) async -> CodeSearchResult? {
        guard let handler = handler.withLock({ $0 }) else { return nil }
        return await handler(workspace, query)
    }
}

/// 把结果排成给模型看的文本:一行一处命中,主目录用相对路径,附加文件夹用绝对路径。
public enum CodeSearchFormatter {
    /// - Parameters:
    ///   - result: 搜索结果
    ///   - workspace: 主目录
    ///   - limit: 展示的命中上限
    public static func format(_ result: CodeSearchResult, workspace: String, limit: Int) -> String {
        if let error = result.error { return "Search failed: \(error)" }
        guard result.totalHits > 0 else { return "No matches found." }
        var lines: [String] = []
        for match in result.matches.prefix(limit) {
            let path = match.root == workspace ? match.path : (match.root as NSString).appendingPathComponent(match.path)
            lines.append("\(path):\(match.line): \(match.preview.trimmingCharacters(in: .whitespaces))")
        }
        var header = "\(result.totalHits) match(es) in \(result.fileCount) file(s)"
        if result.matches.count > limit || result.truncated { header += ", showing the first \(min(limit, result.matches.count)) — narrow the query or use `path` to see more" }
        header += result.indexed ? " [indexed, scanned \(result.scannedFiles) files]" : " [scanned \(result.scannedFiles) files]"
        return header + "\n" + lines.joined(separator: "\n")
    }
}

extension SessionBridge {
    /// `search_code`:在工作区(含附加文件夹)里做索引加速的文本搜索。
    func callSearch(arguments: JSONValue) async -> BridgeResult {
        guard let query = CodeSearchQuery.parse(arguments) else { return BridgeResult("缺少 query 参数", isError: true) }
        guard let workspace = await MainActor.run(body: { model?.workspace.path }) else { return BridgeResult("会话已关闭", isError: true) }
        guard let result = await CodeSearchProvider.shared.search(workspace: workspace, query: query) else {
            return BridgeResult("当前客户端未启用代码搜索索引,请改用自带的 grep", isError: true)
        }
        return BridgeResult(CodeSearchFormatter.format(result, workspace: workspace, limit: query.maxResults), isError: result.error != nil)
    }
}
