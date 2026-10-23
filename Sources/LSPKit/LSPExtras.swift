// @author ixxxxoooo
// LSP 扩展能力:语义标记(semanticTokens)、内嵌提示(inlayHint)、范围/输入时格式化、工作区符号,
// 以及服务器发来的 `workspace/applyEdit` 请求转交宿主应用。

import ACPKit
import Foundation

/// 一个语义标记(行内绝对位置)。
public struct LSPSemanticToken: Sendable, Hashable {
    public var line: Int
    public var character: Int
    public var length: Int
    /// 标记类型名(来自服务器 legend,如 `function`、`class`)。
    public var type: String
    /// 修饰符名集合(如 `declaration`、`static`)。
    public var modifiers: [String]
}

/// 内嵌提示。
public struct LSPInlayHint: Sendable, Hashable {
    public var position: LSPPosition
    /// 展示文本(已把 label parts 拼接)。
    public var label: String
    /// 1 = 类型提示,2 = 参数名提示。
    public var kind: Int?
    public var paddingLeft: Bool
    public var paddingRight: Bool
}

/// 工作区符号搜索结果。
public struct LSPWorkspaceSymbol: Sendable, Hashable, Identifiable {
    public var id: String { "\(name)@\(location.uri):\(location.range.start.line)" }
    public var name: String
    public var kind: LSPSymbolKind
    public var containerName: String?
    public var location: LSPLocation
}

/// 宿主应用 `workspace/applyEdit` 的桥(跨 actor 安全)。
public final class LSPEditBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (LSPWorkspaceEdit) async -> Bool)?

    public init() {}

    /// 设置处理者。
    public func set(_ newHandler: (@Sendable (LSPWorkspaceEdit) async -> Bool)?) {
        lock.lock(); handler = newHandler; lock.unlock()
    }

    private func currentHandler() -> (@Sendable (LSPWorkspaceEdit) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    /// 应用编辑;没有处理者返回 false。
    func apply(_ edit: LSPWorkspaceEdit) async -> Bool {
        guard let current = currentHandler() else { return false }
        return await current(edit)
    }
}

extension LSPDecode {
    /// 解码 `SemanticTokens`(相对编码)。
    /// - Parameters:
    ///   - data: 服务器返回的 `data` 整数数组
    ///   - types: legend.tokenTypes
    ///   - modifiers: legend.tokenModifiers
    static func semanticTokens(data: [Int], types: [String], modifiers: [String]) -> [LSPSemanticToken] {
        var result: [LSPSemanticToken] = []
        result.reserveCapacity(data.count / 5)
        var line = 0, character = 0
        var index = 0
        while index + 4 < data.count {
            let deltaLine = data[index], deltaStart = data[index + 1], length = data[index + 2]
            let typeIndex = data[index + 3], modifierBits = data[index + 4]
            index += 5
            if deltaLine > 0 { line += deltaLine; character = deltaStart } else { character += deltaStart }
            guard types.indices.contains(typeIndex), length > 0 else { continue }
            var names: [String] = []
            for bit in modifiers.indices where modifierBits & (1 << bit) != 0 { names.append(modifiers[bit]) }
            result.append(LSPSemanticToken(line: line, character: character, length: length, type: types[typeIndex], modifiers: names))
        }
        return result
    }

    /// 解码 `InlayHint[]`。
    static func inlayHints(_ value: JSONValue) -> [LSPInlayHint] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard let position = item["position"].flatMap({ try? $0.decode(LSPPosition.self) }) else { return nil }
            let label: String
            if let text = item["label"]?.stringValue {
                label = text
            } else if case .array(let parts)? = item["label"] {
                label = parts.compactMap { $0["value"]?.stringValue }.joined()
            } else {
                return nil
            }
            guard !label.isEmpty else { return nil }
            return LSPInlayHint(position: position, label: label, kind: item["kind"]?.intValue,
                                paddingLeft: item["paddingLeft"]?.boolValue ?? false, paddingRight: item["paddingRight"]?.boolValue ?? false)
        }
    }

    /// 解码 `SymbolInformation[] | WorkspaceSymbol[]`。
    static func workspaceSymbols(_ value: JSONValue) -> [LSPWorkspaceSymbol] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue, let kindRaw = item["kind"]?.intValue,
                  let uri = item["location"]?["uri"]?.stringValue else { return nil }
            let range = item["location"]?["range"].flatMap { try? $0.decode(LSPRange.self) }
                ?? LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
            return LSPWorkspaceSymbol(name: name, kind: LSPSymbolKind(rawValue: kindRaw) ?? .variable,
                                      containerName: item["containerName"]?.stringValue,
                                      location: LSPLocation(uri: uri, range: range))
        }
    }
}

public extension LSPClient {
    /// 服务器是否声明了某能力(能力值为 `true` 或对象)。
    func supports(_ capability: String) -> Bool {
        switch capabilities[capability] {
        case .bool(let value)?: return value
        case .object?: return true
        default: return false
        }
    }

    /// 全量语义标记。服务器不支持返回空数组。
    func semanticTokens(uri: String) async throws -> [LSPSemanticToken] {
        guard let provider = capabilities["semanticTokensProvider"], provider["legend"] != nil else { return [] }
        let types = provider["legend"]?["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let modifiers = provider["legend"]?["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let result = try await request("textDocument/semanticTokens/full", ["textDocument": ["uri": .string(uri)]])
        let data = result["data"]?.arrayValue?.compactMap(\.intValue) ?? []
        return LSPDecode.semanticTokens(data: data, types: types, modifiers: modifiers)
    }

    /// 某范围内的内嵌提示。
    func inlayHints(uri: String, range: LSPRange) async throws -> [LSPInlayHint] {
        guard supports("inlayHintProvider") else { return [] }
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "range": [
                "start": ["line": .int(range.start.line), "character": .int(range.start.character)],
                "end": ["line": .int(range.end.line), "character": .int(range.end.character)],
            ],
        ]
        return LSPDecode.inlayHints(try await request("textDocument/inlayHint", params))
    }

    /// 范围格式化。
    func rangeFormatting(uri: String, range: LSPRange, tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "range": [
                "start": ["line": .int(range.start.line), "character": .int(range.start.character)],
                "end": ["line": .int(range.end.line), "character": .int(range.end.character)],
            ],
            "options": ["tabSize": .int(tabSize), "insertSpaces": .bool(insertSpaces)],
        ]
        return LSPDecode.textEdits(try await request("textDocument/rangeFormatting", params))
    }

    /// 输入触发字符后的格式化(如 `}`、`;`、换行)。
    func onTypeFormatting(uri: String, at position: LSPPosition, character: String, tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        guard supports("documentOnTypeFormattingProvider") else { return [] }
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "position": ["line": .int(position.line), "character": .int(position.character)],
            "ch": .string(character),
            "options": ["tabSize": .int(tabSize), "insertSpaces": .bool(insertSpaces)],
        ]
        return LSPDecode.textEdits(try await request("textDocument/onTypeFormatting", params))
    }

    /// 服务器声明的 on-type 触发字符。
    var onTypeTriggerCharacters: [String] {
        guard let provider = capabilities["documentOnTypeFormattingProvider"] else { return [] }
        var list: [String] = []
        if let first = provider["firstTriggerCharacter"]?.stringValue { list.append(first) }
        list += provider["moreTriggerCharacter"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return list
    }

    /// 服务器声明的补全触发字符。
    var completionTriggerCharacters: [String] {
        capabilities["completionProvider"]?["triggerCharacters"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// 工作区符号搜索(⌘T)。
    func workspaceSymbols(query: String) async throws -> [LSPWorkspaceSymbol] {
        LSPDecode.workspaceSymbols(try await request("workspace/symbol", ["query": .string(query)]))
    }

    /// 设置服务器 `workspace/applyEdit` 的处理者。
    func setApplyEditBridge(_ bridge: LSPEditBridge) { editBridge = bridge }
}
