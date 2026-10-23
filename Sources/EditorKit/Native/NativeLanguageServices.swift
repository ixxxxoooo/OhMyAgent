// @author ixxxxoooo
// 原生编辑器的语言智能扩展点(EditorKit 不依赖 LSPKit):补全、悬停、签名、定义/引用、代码操作、
// 语义着色、内嵌提示、格式化。应用层把 LSP 结果转换成这里的轻量类型并通过回调注入。
// 所有偏移均为 UTF-16 偏移(与 `EditorDocument` 一致)。

import AppKit
import EditorCore

/// 补全项种类(对应 LSP `CompletionItemKind` 的归并)。
public enum NativeCompletionKind: Int, Sendable, Hashable {
    case text = 1, method, function, constructor, field, variable, `class`, interface, module, property
    case unit, value, `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant
    case `struct`, event, `operator`, typeParameter

    /// 列表里显示的单字符徽标。
    public var badge: String {
        switch self {
        case .method, .function, .constructor: "ƒ"
        case .field, .property: "p"
        case .variable, .value, .constant: "v"
        case .class, .struct: "C"
        case .interface: "I"
        case .enum, .enumMember: "E"
        case .module, .file, .folder, .reference: "M"
        case .keyword: "k"
        case .snippet: "⌘"
        case .operator: "±"
        case .typeParameter: "T"
        default: "·"
        }
    }
}

/// 一个补全候选。
public struct NativeCompletionItem: Sendable, Hashable, Identifiable {
    public var id: String { "\(label)|\(detail ?? "")|\(sortText)" }
    public var label: String
    public var detail: String?
    public var documentation: String?
    public var kind: NativeCompletionKind
    /// 纯文本插入内容(无 `snippet` 时使用)。
    public var insertText: String
    /// 原始片段文本(VS Code 语法),存在则走 snippet 引擎插入。
    public var snippet: String?
    /// 服务器指定的替换区间;nil 表示替换光标前的单词前缀。
    public var replaceRange: NSRange?
    public var filterText: String?
    public var sortText: String

    public init(label: String, detail: String? = nil, documentation: String? = nil, kind: NativeCompletionKind = .text,
                insertText: String? = nil, snippet: String? = nil, replaceRange: NSRange? = nil, filterText: String? = nil, sortText: String? = nil) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.insertText = insertText ?? label
        self.snippet = snippet
        self.replaceRange = replaceRange
        self.filterText = filterText
        self.sortText = sortText ?? label
    }
}

/// 代码操作(快速修复/重构)。
public struct NativeCodeActionItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var isQuickFix: Bool
    public var isPreferred: Bool

    public init(id: String, title: String, isQuickFix: Bool = false, isPreferred: Bool = false) {
        self.id = id
        self.title = title
        self.isQuickFix = isQuickFix
        self.isPreferred = isPreferred
    }
}

/// 一个跨文件位置(定义/引用)。
public struct NativeLocation: Sendable, Hashable, Identifiable {
    public var id: String { "\(path):\(line):\(column)" }
    public var path: String
    /// 0 起的行与列。
    public var line: Int
    public var column: Int
    /// 该行的预览文本(用于 Peek 列表)。
    public var preview: String

    public init(path: String, line: Int, column: Int, preview: String = "") {
        self.path = path
        self.line = line
        self.column = column
        self.preview = preview
    }
}

/// 内嵌提示。
public struct NativeInlayHint: Sendable, Hashable {
    public var offset: Int
    public var label: String
    public init(offset: Int, label: String) {
        self.offset = offset
        self.label = label
    }
}

/// 语义着色片段。
public struct NativeSemanticSpan: Sendable, Hashable {
    public var range: NSRange
    public var kind: SyntaxKind
    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// 文本编辑(格式化、代码操作)。
public struct NativeTextEdit: Sendable, Hashable {
    public var range: NSRange
    public var newText: String
    public init(range: NSRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// 语言智能回调集合(主线程)。服务器未就绪时全部为 nil。
public struct NativeLanguageServices {
    /// 编辑器接入时回调(应用层保存句柄,用于应用编辑、读取文本)。
    public var attach: (@MainActor (_ editor: NativeLanguageController) -> Void)?
    /// 请求前把最新文本同步给服务器(位置与文本必须一致)。
    public var prepare: (@MainActor (_ text: @MainActor () -> String) -> Void)?
    public var hover: (@MainActor (_ offset: Int) async -> String?)?
    public var definition: (@MainActor (_ offset: Int) async -> [NativeLocation])?
    public var references: (@MainActor (_ offset: Int) async -> [NativeLocation])?
    /// 打开某个位置(跨文件)。
    public var openLocation: (@MainActor (NativeLocation) -> Void)?
    public var completion: (@MainActor (_ offset: Int) async -> [NativeCompletionItem])?
    /// 自动触发补全的字符。
    public var completionTriggers: Set<Character> = [".", ":", "(", "<", "\"", "/", "@"]
    public var signatureHelp: (@MainActor (_ offset: Int) async -> EditorSignature?)?
    public var codeActions: (@MainActor (_ range: NSRange) async -> [NativeCodeActionItem])?
    /// 执行代码操作(由应用层负责取编辑并回调应用)。
    public var runCodeAction: (@MainActor (NativeCodeActionItem) async -> Void)?
    public var inlayHints: (@MainActor (_ range: NSRange) async -> [NativeInlayHint])?
    public var semanticSpans: (@MainActor () async -> [NativeSemanticSpan])?
    /// 格式化:传 nil 表示整个文档。
    public var format: (@MainActor (_ range: NSRange?) async -> [NativeTextEdit])?
    /// 输入某字符后的格式化(`}`、`;`、换行)。
    public var onTypeFormat: (@MainActor (_ offset: Int, _ character: Character) async -> [NativeTextEdit])?
    /// 触发 on-type 格式化的字符。
    public var onTypeTriggers: Set<Character> = []

    public init() {}

    /// 是否没有任何能力(服务器未就绪)。
    public var isEmpty: Bool {
        hover == nil && definition == nil && completion == nil && signatureHelp == nil && codeActions == nil
            && inlayHints == nil && semanticSpans == nil && format == nil && references == nil
    }
}

/// 补全模糊匹配(纯函数)。
public enum NativeCompletionMatcher {
    /// 匹配结果。
    public struct Match: Sendable, Equatable {
        public var score: Int
        /// 命中的字符下标(`candidate` 的 Character 序)。
        public var indices: [Int]
    }

    /// 子序列模糊匹配:前缀、大小写、单词边界、连续命中加分。
    /// - Parameters:
    ///   - query: 已输入的前缀(空串匹配一切)
    ///   - candidate: 候选文本
    /// - Returns: 命中得分与下标;不匹配返回 nil
    public static func match(query: String, candidate: String) -> Match? {
        if query.isEmpty { return Match(score: 0, indices: []) }
        let q = Array(query), c = Array(candidate)
        guard q.count <= c.count else { return nil }
        var indices: [Int] = []
        var score = 0
        var ci = 0
        var previous = -2
        for ch in q {
            var found = false
            while ci < c.count {
                let current = c[ci]
                if current.lowercased() == ch.lowercased() {
                    var bonus = 1
                    if current == ch { bonus += 1 }
                    if ci == 0 { bonus += 8 }
                    else if isBoundary(c[ci - 1], current) { bonus += 5 }
                    if previous == ci - 1 { bonus += 4 }
                    score += bonus
                    indices.append(ci)
                    previous = ci
                    ci += 1
                    found = true
                    break
                }
                ci += 1
            }
            if !found { return nil }
        }
        // 越短越优先;整词前缀额外加分。
        score -= (c.count - q.count) / 4
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 10 }
        return Match(score: score, indices: indices)
    }

    private static func isBoundary(_ before: Character, _ current: Character) -> Bool {
        if before == "_" || before == "-" || before == "." || before == "/" || before == " " { return true }
        return before.isLowercase && current.isUppercase
    }

    /// 过滤并排序候选。
    /// - Parameters:
    ///   - items: 全部候选
    ///   - query: 已输入前缀
    ///   - limit: 最多返回条数
    /// - Returns: 候选及其命中下标,按得分降序、`sortText` 升序
    public static func filter(_ items: [NativeCompletionItem], query: String, limit: Int = 200) -> [(item: NativeCompletionItem, indices: [Int])] {
        var scored: [(item: NativeCompletionItem, match: Match)] = []
        scored.reserveCapacity(min(items.count, 512))
        for item in items {
            if let result = match(query: query, candidate: item.filterText ?? item.label) { scored.append((item, result)) }
        }
        scored.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            return lhs.item.sortText < rhs.item.sortText
        }
        return scored.prefix(limit).map { ($0.item, $0.match.indices) }
    }

    /// 取光标前的标识符前缀起点。
    /// - Parameters:
    ///   - rope: 文档
    ///   - offset: 光标偏移
    public static func wordStart(before offset: Int, in rope: TextRope) -> Int {
        var start = offset
        let lineStart = rope.lineStart(rope.line(containing: offset))
        while start > lineStart {
            guard let unit = rope.unit(at: start - 1) else { break }
            let isWord = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit > 0x7F
            if !isWord { break }
            start -= 1
        }
        return start
    }
}
