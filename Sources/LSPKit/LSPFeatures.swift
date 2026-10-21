// @author ixxxxoooo
// LSP 扩展能力(I8):引用、文档符号(大纲)、重命名、格式化、签名帮助的模型、解码与纯函数文本编辑应用。

import ACPKit
import Foundation

/// 符号种类(LSP `SymbolKind` 的常用子集)。
public enum LSPSymbolKind: Int, Sendable {
    case file = 1, module, namespace, package, `class`, method, property, field, constructor, `enum`, interface
    case function, variable, constant, string, number, boolean, array, object, key, null, enumMember, `struct`, event, `operator`, typeParameter

    /// 大纲里使用的 Lucide 图标名。
    public var iconName: String {
        switch self {
        case .class, .struct, .interface, .enum: "braces"
        case .function, .method, .constructor: "code"
        case .property, .field, .variable, .constant, .enumMember: "tag"
        case .module, .namespace, .package, .file: "puzzle"
        default: "hash"
        }
    }
}

/// 文档符号(层级结构;`SymbolInformation` 会被拍平为无子级)。
public struct LSPSymbol: Sendable, Hashable, Identifiable {
    public var id: String { "\(name)@\(line):\(character)" }
    public var name: String
    public var detail: String?
    public var kind: LSPSymbolKind
    /// 符号选择范围的起点行(0 起始)与列
    public var line: Int
    public var character: Int
    /// 整个符号覆盖的结束行(0 起始,含)
    public var endLine: Int
    public var children: [LSPSymbol]

    public init(name: String, detail: String? = nil, kind: LSPSymbolKind, line: Int, character: Int = 0, endLine: Int, children: [LSPSymbol] = []) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.line = line
        self.character = character
        self.endLine = endLine
        self.children = children
    }

    /// 深度优先拍平(带层级深度),大纲列表用。
    /// - Returns: (符号, 深度)序列
    public func flattened(depth: Int = 0) -> [(symbol: LSPSymbol, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }
}

/// 一处文本编辑。
public struct LSPTextEdit: Sendable, Hashable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// 工作区编辑:文档 URI → 编辑列表。
public struct LSPWorkspaceEdit: Sendable, Equatable {
    public var changes: [String: [LSPTextEdit]]

    public init(changes: [String: [LSPTextEdit]] = [:]) { self.changes = changes }

    /// 涉及的编辑总数。
    public var editCount: Int { changes.values.reduce(0) { $0 + $1.count } }
}

/// 签名帮助(当前激活的签名与参数)。
public struct LSPSignatureHelp: Sendable, Equatable {
    public var label: String
    /// 当前参数在 `label` 里的 UTF-16 范围;未知为 nil
    public var activeParameter: NSRange?

    public init(label: String, activeParameter: NSRange? = nil) {
        self.label = label
        self.activeParameter = activeParameter
    }
}

/// 文本编辑的纯函数应用。
public enum LSPTextEdits {
    /// 把 LSP 位置(行 + UTF-16 列)换算为文本里的 UTF-16 偏移;越界钳制到行尾/文末。
    /// - Parameters:
    ///   - position: LSP 位置
    ///   - lineStarts: 每行起点的 UTF-16 偏移
    ///   - length: 文本总长度(UTF-16)
    public static func offset(of position: LSPPosition, lineStarts: [Int], length: Int) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < lineStarts.count else { return length }
        let start = lineStarts[position.line]
        let end = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] : length
        return min(start + max(position.character, 0), end)
    }

    /// 计算每行起点(UTF-16 偏移)。
    /// - Parameter text: 文本
    public static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        return starts
    }

    /// 应用一组编辑(按范围从后往前替换,互不影响;重叠的编辑后者被忽略)。
    /// - Parameters:
    ///   - edits: 编辑
    ///   - text: 原文
    /// - Returns: 新文本
    public static func apply(_ edits: [LSPTextEdit], to text: String) -> String {
        let starts = lineStarts(of: text)
        let ns = text as NSString
        let resolved = edits.map { edit -> (NSRange, String) in
            let from = offset(of: edit.range.start, lineStarts: starts, length: ns.length)
            let to = max(from, offset(of: edit.range.end, lineStarts: starts, length: ns.length))
            return (NSRange(location: from, length: to - from), edit.newText)
        }.sorted { $0.0.location != $1.0.location ? $0.0.location < $1.0.location : $0.0.length > $1.0.length }
        // 与前一个已保留编辑重叠的丢弃(起点相同时保留更长的)
        var kept: [(NSRange, String)] = []
        for item in resolved {
            if let last = kept.last, item.0.location < NSMaxRange(last.0) { continue }
            kept.append(item)
        }
        var result = ns
        for (range, replacement) in kept.reversed() {
            result = result.replacingCharacters(in: range, with: replacement) as NSString
        }
        return result as String
    }
}

extension LSPDecode {
    /// 解析 `DocumentSymbol[] | SymbolInformation[]`。
    static func symbols(_ value: JSONValue) -> [LSPSymbol] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap(symbol)
    }

    private static func symbol(_ item: JSONValue) -> LSPSymbol? {
        guard let name = item["name"]?.stringValue, let kindRaw = item["kind"]?.intValue else { return nil }
        let kind = LSPSymbolKind(rawValue: kindRaw) ?? .variable
        // DocumentSymbol:range + selectionRange;SymbolInformation:location.range
        let full = (item["range"] ?? item["location"]?["range"]).flatMap { try? $0.decode(LSPRange.self) }
        let selection = item["selectionRange"].flatMap { try? $0.decode(LSPRange.self) } ?? full
        guard let selection else { return nil }
        let children = item["children"].map { symbols($0) } ?? []
        return LSPSymbol(name: name, detail: item["detail"]?.stringValue, kind: kind, line: selection.start.line,
                         character: selection.start.character, endLine: max(full?.end.line ?? selection.end.line, selection.end.line), children: children)
    }

    /// 解析 `WorkspaceEdit`(`changes` 或 `documentChanges` 里的 TextDocumentEdit;资源操作忽略)。
    static func workspaceEdit(_ value: JSONValue) -> LSPWorkspaceEdit {
        var result: [String: [LSPTextEdit]] = [:]
        func edits(_ array: JSONValue?) -> [LSPTextEdit] {
            guard case .array(let items)? = array else { return [] }
            return items.compactMap { item in
                guard let range = item["range"].flatMap({ try? $0.decode(LSPRange.self) }), let text = item["newText"]?.stringValue else { return nil }
                return LSPTextEdit(range: range, newText: text)
            }
        }
        if case .object(let changes)? = value["changes"] {
            for (uri, list) in changes { result[uri, default: []] += edits(list) }
        }
        if case .array(let documentChanges)? = value["documentChanges"] {
            for change in documentChanges {
                guard let uri = change["textDocument"]?["uri"]?.stringValue else { continue }
                result[uri, default: []] += edits(change["edits"])
            }
        }
        return LSPWorkspaceEdit(changes: result)
    }

    /// 解析 `TextEdit[]`。
    static func textEdits(_ value: JSONValue) -> [LSPTextEdit] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard let range = item["range"].flatMap({ try? $0.decode(LSPRange.self) }), let text = item["newText"]?.stringValue else { return nil }
            return LSPTextEdit(range: range, newText: text)
        }
    }

    /// 解析 `SignatureHelp`:取激活的签名与参数(参数可为标签文本或 [起, 止] 偏移)。
    static func signatureHelp(_ value: JSONValue) -> LSPSignatureHelp? {
        guard case .array(let signatures)? = value["signatures"], !signatures.isEmpty else { return nil }
        let index = min(max(value["activeSignature"]?.intValue ?? 0, 0), signatures.count - 1)
        let signature = signatures[index]
        guard let label = signature["label"]?.stringValue else { return nil }
        var range: NSRange?
        let parameterIndex = signature["activeParameter"]?.intValue ?? value["activeParameter"]?.intValue ?? 0
        if case .array(let parameters)? = signature["parameters"], parameters.indices.contains(parameterIndex) {
            let parameterLabel = parameters[parameterIndex]["label"]
            if let text = parameterLabel?.stringValue {
                let found = (label as NSString).range(of: text)
                if found.location != NSNotFound { range = found }
            } else if case .array(let pair)? = parameterLabel, pair.count == 2, let from = pair[0].intValue, let to = pair[1].intValue, to >= from {
                range = NSRange(location: from, length: to - from)
            }
        }
        return LSPSignatureHelp(label: label, activeParameter: range)
    }
}

public extension LSPClient {
    /// 查找引用(包含声明)。
    func references(uri: String, at position: LSPPosition) async throws -> [LSPLocation] {
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "position": ["line": .int(position.line), "character": .int(position.character)],
            "context": ["includeDeclaration": true],
        ]
        return LSPDecode.locations(try await request("textDocument/references", params))
    }

    /// 文档符号(大纲)。
    func documentSymbols(uri: String) async throws -> [LSPSymbol] {
        LSPDecode.symbols(try await request("textDocument/documentSymbol", ["textDocument": ["uri": .string(uri)]]))
    }

    /// 重命名符号。
    /// - Returns: 需要应用的工作区编辑;服务器不支持返回空编辑
    func rename(uri: String, at position: LSPPosition, newName: String) async throws -> LSPWorkspaceEdit {
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "position": ["line": .int(position.line), "character": .int(position.character)],
            "newName": .string(newName),
        ]
        return LSPDecode.workspaceEdit(try await request("textDocument/rename", params))
    }

    /// 格式化整个文档。
    func formatting(uri: String, tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "options": ["tabSize": .int(tabSize), "insertSpaces": .bool(insertSpaces)],
        ]
        return LSPDecode.textEdits(try await request("textDocument/formatting", params))
    }

    /// 签名帮助。
    func signatureHelp(uri: String, at position: LSPPosition) async throws -> LSPSignatureHelp? {
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "position": ["line": .int(position.line), "character": .int(position.character)],
        ]
        return LSPDecode.signatureHelp(try await request("textDocument/signatureHelp", params))
    }
}
