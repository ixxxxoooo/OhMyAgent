// @author ixxxxoooo
// LSP 协议数据模型(只覆盖客户端用到的子集)。位置单位为 UTF-16 代码单元(LSP 默认编码,与 NSString 一致)。

import ACPKit
import Foundation

/// 文本位置(行、列均 0 起始)。
public struct LSPPosition: Sendable, Hashable, Codable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// 文本范围(左闭右开)。
public struct LSPRange: Sendable, Hashable, Codable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// 诊断严重程度。
public enum LSPSeverity: Int, Sendable, Hashable, Codable {
    case error = 1, warning = 2, information = 3, hint = 4
}

/// 一条诊断。
public struct LSPDiagnostic: Sendable, Hashable, Codable {
    public var range: LSPRange
    /// 缺省按错误处理(协议允许服务器不填)
    public var severity: LSPSeverity?
    public var message: String
    public var source: String?

    public init(range: LSPRange, severity: LSPSeverity? = nil, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    /// 生效的严重程度。
    public var effectiveSeverity: LSPSeverity { severity ?? .error }
}

/// 一次诊断发布。
public struct LSPDiagnosticsUpdate: Sendable, Hashable {
    public var uri: String
    public var version: Int?
    public var diagnostics: [LSPDiagnostic]

    public init(uri: String, version: Int?, diagnostics: [LSPDiagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }
}

/// 位置(文件 + 范围)。
public struct LSPLocation: Sendable, Hashable {
    public var uri: String
    public var range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// 补全项。
public struct LSPCompletionItem: Sendable, Hashable {
    public var label: String
    public var detail: String?
    /// 实际插入文本(已去除片段占位符);无则用 `label`
    public var insertText: String
    /// LSP `CompletionItemKind` 数值
    public var kind: Int?
    public var sortText: String
    /// 原始片段文本(`insertTextFormat == 2` 时才有,保留 `$1`、`${1:x}` 占位)。
    public var snippet: String?
    /// 服务器指定的替换区间(`textEdit.range`);无则按光标前的单词前缀替换。
    public var replaceRange: LSPRange?
    /// 文档说明(纯文本/Markdown)。
    public var documentation: String?
    /// 参与过滤的文本;无则用 `label`。
    public var filterText: String?

    public init(label: String, detail: String? = nil, insertText: String? = nil, kind: Int? = nil, sortText: String? = nil,
                snippet: String? = nil, replaceRange: LSPRange? = nil, documentation: String? = nil, filterText: String? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText ?? label
        self.kind = kind
        self.sortText = sortText ?? label
        self.snippet = snippet
        self.replaceRange = replaceRange
        self.documentation = documentation
        self.filterText = filterText
    }
}

/// 服务器状态。
public enum LSPClientState: Sendable, Equatable {
    case idle, starting, ready
    case failed(String)
    case closed
}

/// 解析响应用的工具。
enum LSPDecode {
    /// 解析 `Location | Location[] | LocationLink[]`。
    static func locations(_ value: JSONValue) -> [LSPLocation] {
        let items: [JSONValue]
        switch value {
        case .array(let array): items = array
        case .object: items = [value]
        default: return []
        }
        return items.compactMap { item in
            // LocationLink 用 targetUri/targetSelectionRange;Location 用 uri/range
            let uri = item["targetUri"]?.stringValue ?? item["uri"]?.stringValue
            let rangeValue = item["targetSelectionRange"] ?? item["targetRange"] ?? item["range"]
            guard let uri, let rangeValue, let range = try? rangeValue.decode(LSPRange.self) else { return nil }
            return LSPLocation(uri: uri, range: range)
        }
    }

    /// 把 hover 的 contents(MarkupContent | MarkedString | MarkedString[])拼成纯文本。
    static func hoverText(_ value: JSONValue) -> String? {
        guard let contents = value["contents"] else { return nil }
        // MarkupContent / MarkedString 都是「字符串或带 value 的对象」
        func piece(_ part: JSONValue) -> String? {
            switch part {
            case .string(let string): return string
            case .object: return part["value"]?.stringValue
            default: return nil
            }
        }
        let joined: String
        if case .array(let parts) = contents {
            joined = parts.compactMap { piece($0) }.joined(separator: "\n\n")
        } else {
            joined = piece(contents) ?? ""
        }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解析 `CompletionItem[] | CompletionList`。
    static func completions(_ value: JSONValue) -> [LSPCompletionItem] {
        let items: [JSONValue]
        switch value {
        case .array(let array): items = array
        case .object: items = value["items"]?.arrayValue ?? []
        default: items = []
        }
        return items.compactMap { item in
            guard let label = item["label"]?.stringValue, !label.isEmpty else { return nil }
            let raw = item["textEdit"]?["newText"]?.stringValue ?? item["insertText"]?.stringValue ?? label
            let isSnippet = item["insertTextFormat"]?.intValue == 2
            return LSPCompletionItem(
                label: label,
                detail: item["detail"]?.stringValue,
                insertText: isSnippet ? stripSnippet(raw) : raw,
                kind: item["kind"]?.intValue,
                sortText: item["sortText"]?.stringValue,
                snippet: isSnippet ? raw : nil,
                replaceRange: (item["textEdit"]?["range"] ?? item["textEdit"]?["replace"]).flatMap { try? $0.decode(LSPRange.self) },
                documentation: item["documentation"]?.stringValue ?? item["documentation"]?["value"]?.stringValue,
                filterText: item["filterText"]?.stringValue
            )
        }
    }

    /// 去除片段语法:`${1:name}` → `name`,`$1`/`$0` 删除,`\$` 还原。
    static func stripSnippet(_ snippet: String) -> String {
        var result = ""
        var index = snippet.startIndex
        while index < snippet.endIndex {
            let char = snippet[index]
            let next = snippet.index(after: index)
            if char == "\\", next < snippet.endIndex {
                result.append(snippet[next])
                index = snippet.index(after: next)
            } else if char == "$", next < snippet.endIndex {
                if snippet[next] == "{", let close = snippet[next...].firstIndex(of: "}") {
                    let inner = snippet[snippet.index(after: next)..<close]
                    if let colon = inner.firstIndex(of: ":") { result += inner[inner.index(after: colon)...] }
                    index = snippet.index(after: close)
                } else if snippet[next].isNumber {
                    var end = next
                    while end < snippet.endIndex, snippet[end].isNumber { end = snippet.index(after: end) }
                    index = end
                } else {
                    result.append(char)
                    index = next
                }
            } else {
                result.append(char)
                index = next
            }
        }
        return result
    }
}
