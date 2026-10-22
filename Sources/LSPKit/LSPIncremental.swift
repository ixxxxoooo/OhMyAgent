// @author ixxxxoooo
// LSP 增量文本同步(由前后文本求出最小单段变更)与代码操作(Code Action)的解码与请求。

import ACPKit
import Foundation

/// 一处内容变更;`range == nil` 表示整篇替换。
public struct LSPContentChange: Sendable, Equatable {
    /// 旧文本里被替换的范围
    public var range: LSPRange?
    /// 替换文本
    public var text: String

    public init(range: LSPRange?, text: String) {
        self.range = range
        self.text = text
    }
}

/// 由前后两个文本求出一处最小变更(公共前缀/后缀法)。
public enum LSPTextDiff {
    /// - Parameters:
    ///   - old: 服务器已知的旧文本
    ///   - new: 新文本
    /// - Returns: 变更;两者相同返回 nil。范围基于旧文本、UTF-16 列,且不会落在代理对中间
    public static func change(from old: String, to new: String) -> LSPContentChange? {
        guard old != new else { return nil }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        let limit = min(a.count, b.count)
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        // 不要把一个代理对从中间切开
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let oldEnd = a.count - suffix
        let newEnd = b.count - suffix
        let replacement = String(decoding: b[prefix..<newEnd], as: UTF16.self)
        let starts = LSPTextEdits.lineStarts(of: old)
        return LSPContentChange(
            range: LSPRange(start: position(of: prefix, lineStarts: starts), end: position(of: oldEnd, lineStarts: starts)),
            text: replacement
        )
    }

    /// UTF-16 偏移 → LSP 位置(二分查找所在行)。
    static func position(of offset: Int, lineStarts: [Int]) -> LSPPosition {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return LSPPosition(line: low, character: offset - lineStarts[low])
    }
}

/// 一个代码操作(快速修复/重构)。
public struct LSPCodeAction: Sendable, Equatable {
    public var title: String
    public var kind: String?
    /// 直接携带的编辑;nil 时可能需要 `codeAction/resolve`
    public var edit: LSPWorkspaceEdit?
    /// 服务器推荐的首选操作
    public var isPreferred: Bool
    /// 原始 JSON(resolve 时回传)
    public var raw: JSONValue

    public init(title: String, kind: String?, edit: LSPWorkspaceEdit?, isPreferred: Bool, raw: JSONValue) {
        self.title = title
        self.kind = kind
        self.edit = edit
        self.isPreferred = isPreferred
        self.raw = raw
    }
}

extension LSPDecode {
    /// 解析 `(Command | CodeAction)[]`。纯命令(没有 edit 也没有 data)客户端无法执行,丢弃。
    static func codeActions(_ value: JSONValue) -> [LSPCodeAction] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            guard let title = item["title"]?.stringValue else { return nil }
            let edit = item["edit"].map(workspaceEdit)
            let editable = (edit?.editCount ?? 0) > 0
            guard editable || item["data"] != nil else { return nil }
            return LSPCodeAction(title: title, kind: item["kind"]?.stringValue, edit: editable ? edit : nil,
                                 isPreferred: item["isPreferred"]?.boolValue ?? false, raw: item)
        }
    }
}

public extension LSPClient {
    /// 请求某范围的代码操作。
    /// - Parameters:
    ///   - uri: 文档
    ///   - range: 范围(光标处为空范围)
    ///   - diagnostics: 与该范围相交的诊断(服务器据此给出快速修复)
    func codeActions(uri: String, range: LSPRange, diagnostics: [LSPDiagnostic]) async throws -> [LSPCodeAction] {
        func pos(_ p: LSPPosition) -> JSONValue { ["line": .int(p.line), "character": .int(p.character)] }
        let encoded = diagnostics.compactMap { try? JSONValue.from($0) }
        let params: JSONValue = [
            "textDocument": ["uri": .string(uri)],
            "range": ["start": pos(range.start), "end": pos(range.end)],
            "context": ["diagnostics": .array(encoded)],
        ]
        return LSPDecode.codeActions(try await request("textDocument/codeAction", params))
    }

    /// 补全一个缺少 `edit` 的代码操作(`codeAction/resolve`)。
    func resolve(_ action: LSPCodeAction) async throws -> LSPCodeAction {
        if action.edit != nil { return action }
        let result = try await request("codeAction/resolve", action.raw)
        let edit = result["edit"].map(LSPDecode.workspaceEdit)
        var resolved = action
        resolved.edit = (edit?.editCount ?? 0) > 0 ? edit : nil
        return resolved
    }
}
