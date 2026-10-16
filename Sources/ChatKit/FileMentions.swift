// @author ixxxxoooo
// 草稿里的 `@文件` 提及解析:把 `@path` / `@"带空格的 path"` 识别为可展示成 chip 的文件或文件夹。
// 只识别真实存在的路径(`@agent-xxx`、`@某人` 等不会被当成文件)。

import Foundation

/// 草稿中的一处文件/文件夹提及。
public struct FileMention: Identifiable, Equatable, Sendable {
    /// 提及在草稿中的完整记号(含 `@` 与引号),同一路径重复出现时取首个
    public let token: String
    /// 解析后的绝对路径
    public let path: String
    /// 是否文件夹
    public let isDirectory: Bool

    public var id: String { token }
    /// 展示用文件名
    public var name: String { (path as NSString).lastPathComponent }
}

/// 文件提及解析器。
public enum FileMentions {
    /// 解析草稿里的文件提及(去重,保持出现顺序)。
    /// - Parameters:
    ///   - text: 草稿文本
    ///   - workspace: 工作区目录(相对路径的基准)
    ///   - exists: 路径存在性判断(默认查文件系统,测试可注入);返回 nil 表示不存在,否则返回是否目录
    /// - Returns: 存在的文件/文件夹提及
    public static func parse(
        _ text: String,
        workspace: URL,
        exists: (String) -> Bool? = FileMentions.fileSystemExists
    ) -> [FileMention] {
        var result: [FileMention] = []
        var seen = Set<String>()
        for token in tokens(in: text) {
            guard seen.insert(token.raw).inserted else { continue }
            let absolute = resolve(token.value, workspace: workspace)
            guard let isDirectory = exists(absolute) else { continue }
            result.append(FileMention(token: token.raw, path: absolute, isDirectory: isDirectory))
        }
        return result
    }

    /// 一次提及在草稿中的出现位置(含重复出现)。
    public struct Occurrence: Equatable, Sendable {
        /// 提及信息
        public let mention: FileMention
        /// 记号在草稿中的范围
        public let range: Range<String.Index>
    }

    /// 解析草稿里**所有**文件提及的出现位置(不去重,按出现顺序),供输入框内联 chip 使用。
    /// - Parameters:
    ///   - text: 草稿文本
    ///   - workspace: 工作区目录
    ///   - exists: 路径存在性判断(默认查文件系统)
    /// - Returns: 每处存在的提及及其范围
    public static func occurrences(
        in text: String,
        workspace: URL,
        exists: (String) -> Bool? = FileMentions.fileSystemExists
    ) -> [Occurrence] {
        var result: [Occurrence] = []
        for token in tokens(in: text) {
            let absolute = resolve(token.value, workspace: workspace)
            guard let isDirectory = exists(absolute) else { continue }
            result.append(Occurrence(
                mention: FileMention(token: token.raw, path: absolute, isDirectory: isDirectory),
                range: token.range
            ))
        }
        return result
    }

    /// 从草稿中移除某个提及(连同其后紧跟的一个空格)。
    /// - Parameters:
    ///   - mention: 要移除的提及
    ///   - text: 草稿文本
    /// - Returns: 移除后的文本
    public static func remove(_ mention: FileMention, from text: String) -> String {
        var result = text
        for token in tokens(in: text) where token.raw == mention.token {
            var end = token.range.upperBound
            if end < result.endIndex, result[end] == " " { end = result.index(after: end) }
            result.removeSubrange(token.range.lowerBound..<end)
            break
        }
        return result
    }

    /// 默认的存在性判断:存在则返回是否目录。
    public static func fileSystemExists(_ path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    // MARK: - 内部

    private struct Token {
        let raw: String
        let value: String
        let range: Range<String.Index>
    }

    /// 扫描 `@` 记号:必须位于文本开头或空白之后。
    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let atBoundary = index == text.startIndex || text[text.index(before: index)].isWhitespace
            guard char == "@", atBoundary else { index = text.index(after: index); continue }
            let start = index
            var cursor = text.index(after: index)
            guard cursor < text.endIndex else { break }
            var value = ""
            if text[cursor] == "\"" {
                cursor = text.index(after: cursor)
                guard let close = text[cursor...].firstIndex(of: "\"") else { index = cursor; continue }
                value = String(text[cursor..<close])
                cursor = text.index(after: close)
            } else {
                let end = text[cursor...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                value = String(text[cursor..<end])
                cursor = end
            }
            if !value.isEmpty { result.append(Token(raw: String(text[start..<cursor]), value: value, range: start..<cursor)) }
            index = cursor
        }
        return result
    }

    /// 相对路径按工作区解析;`~` 展开;绝对路径原样。
    private static func resolve(_ value: String, workspace: URL) -> String {
        let trimmed = value.hasSuffix("/") && value.count > 1 ? String(value.dropLast()) : value
        if trimmed.hasPrefix("/") { return trimmed }
        if trimmed.hasPrefix("~") { return (trimmed as NSString).expandingTildeInPath }
        return workspace.appendingPathComponent(trimmed).standardizedFileURL.path
    }
}
