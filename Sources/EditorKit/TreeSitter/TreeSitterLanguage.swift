// @author ixxxxoooo
// tree-sitter 语言资源:语法指针 + 已编译的高亮查询 + 捕获名到 `SyntaxKind` 的映射 + 文本谓词求值。
// 同一语言进程内只编译一次(查询对象只读,可跨解析器共享)。

import CTreeSitter
import Foundation
import OMLog
import Synchronization
import TreeSitterGrammars

/// 查询里的文本谓词(tree-sitter 的 C 库不求值,需要自己做)。
enum TreeSitterPredicate: @unchecked Sendable {
    /// `#eq?` / `#not-eq?`:捕获文本与另一捕获或字面量比较
    case equals(capture: UInt32, otherCapture: UInt32?, literal: String?, negate: Bool)
    /// `#match?` / `#not-match?`:捕获文本匹配正则
    case matches(capture: UInt32, regex: NSRegularExpression, negate: Bool)
    /// `#any-of?` / `#not-any-of?`:捕获文本在集合内
    case anyOf(capture: UInt32, values: Set<String>, negate: Bool)
}

/// 一种语言的 tree-sitter 资源。
final class TreeSitterLanguage: @unchecked Sendable {
    /// 语法指针(静态数据,永不释放)
    let language: OpaquePointer
    /// 已编译的高亮查询
    let query: OpaquePointer
    /// 捕获序号 → 高亮类别(没有对应类别的捕获为 nil)
    let captureKinds: [SyntaxKind?]
    /// 模式序号 → 文本谓词(没有谓词的模式不在表里)
    let predicates: [Int: [TreeSitterPredicate]]

    init(language: OpaquePointer, query: OpaquePointer, captureKinds: [SyntaxKind?], predicates: [Int: [TreeSitterPredicate]]) {
        self.language = language
        self.query = query
        self.captureKinds = captureKinds
        self.predicates = predicates
    }

    deinit { ts_query_delete(query) }

    // MARK: 注册表

    /// 编译缓存:`nil` 值表示该语言不支持或编译失败(不重复尝试)。
    private static let cache = Mutex<[SyntaxLanguage: TreeSitterLanguage?]>([:])

    /// 取某语言的资源;不支持的语言或查询无法编译时返回 nil。
    /// - Parameter language: 编辑器语言
    static func resolve(_ language: SyntaxLanguage) -> TreeSitterLanguage? {
        cache.withLock { table in
            if let cached = table[language] { return cached }
            let built = build(language)
            table[language] = .some(built)
            return built
        }
    }

    /// 该语言是否由 tree-sitter 提供高亮(不触发编译)。
    static func isSupported(_ language: SyntaxLanguage) -> Bool { grammarName(language) != nil }

    /// 语言 → 语法名(同时是 `TreeSitterQueries` 的键)。
    private static func grammarName(_ language: SyntaxLanguage) -> String? {
        switch language {
        case .swift: "swift"
        case .javascript: "javascript"
        case .typescript: "typescript"
        case .python: "python"
        case .json: "json"
        case .rust: "rust"
        case .go: "go"
        case .css: "css"
        case .html: "html"
        default: nil
        }
    }

    /// 语法入口。
    private static func grammar(_ name: String) -> OpaquePointer? {
        switch name {
        case "swift": tree_sitter_swift()
        case "javascript": tree_sitter_javascript()
        case "typescript": tree_sitter_typescript()
        case "python": tree_sitter_python()
        case "json": tree_sitter_json()
        case "rust": tree_sitter_rust()
        case "go": tree_sitter_go()
        case "css": tree_sitter_css()
        case "html": tree_sitter_html()
        default: nil
        }
    }

    private static func build(_ language: SyntaxLanguage) -> TreeSitterLanguage? {
        guard let name = grammarName(language), let pointer = grammar(name), let source = TreeSitterQueries.highlights[name] else { return nil }
        let started = ContinuousClock.now
        // 逐条验证模式:个别模式引用了该语法没有的节点类型时丢弃它,而不是整个查询失败
        let patterns = TreeSitterQuerySplitter.split(source)
        var valid: [String] = []
        var dropped = 0
        for pattern in patterns {
            if compile(pointer, pattern) != nil { valid.append(pattern) } else { dropped += 1 }
        }
        let merged = valid.joined(separator: "\n")
        guard let query = compile(pointer, merged) else {
            Log.editor.warning("tree-sitter 高亮查询编译失败,退回词法高亮", ["language": name])
            return nil
        }
        let captureCount = Int(ts_query_capture_count(query))
        var kinds: [SyntaxKind?] = []
        kinds.reserveCapacity(captureCount)
        for index in 0..<captureCount {
            var length: UInt32 = 0
            guard let raw = ts_query_capture_name_for_id(query, UInt32(index), &length) else { kinds.append(nil); continue }
            kinds.append(kind(forCapture: String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), count: Int(length)), as: UTF8.self)))
        }
        let table = extractPredicates(query)
        let elapsed = ContinuousClock.now - started
        Log.editor.info("tree-sitter 语言就绪", [
            "language": name, "patterns": "\(Int(ts_query_pattern_count(query)))", "dropped": "\(dropped)",
            "ms": String(format: "%.1f", Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000),
        ])
        return TreeSitterLanguage(language: pointer, query: query, captureKinds: kinds, predicates: table)
    }

    /// 编译一段查询;失败返回 nil。
    private static func compile(_ language: OpaquePointer, _ source: String) -> OpaquePointer? {
        var offset: UInt32 = 0
        var error = TSQueryErrorNone
        let bytes = Array(source.utf8)
        let query = bytes.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            guard let base = buffer.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ts_query_new(language, $0, UInt32(buffer.count), &offset, &error)
            }
        }
        return error == TSQueryErrorNone ? query : nil
    }

    /// 捕获名 → 高亮类别;没有对应类别(标点、变量、拼写等)返回 nil。
    static func kind(forCapture name: String) -> SyntaxKind? {
        if name.hasPrefix("_") { return nil }
        let head = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "boolean": return .keyword
        case "string", "character", "escape": return .string
        case "comment": return .comment
        case "number", "float": return .number
        case "type", "constructor", "namespace", "module": return .type
        case "function", "method": return .function
        case "property", "field", "attribute", "tag", "label": return head == "tag" ? .keyword : .property
        case "constant": return name == "constant.builtin" || name == "constant.macro" ? .keyword : nil
        case "variable": return name == "variable.builtin" ? .keyword : (name == "variable.member" ? .property : nil)
        default: return nil
        }
    }

    /// 读出每个模式的文本谓词。
    private static func extractPredicates(_ query: OpaquePointer) -> [Int: [TreeSitterPredicate]] {
        var table: [Int: [TreeSitterPredicate]] = [:]
        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            guard let raw = ts_query_string_value_for_id(query, id, &length) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), count: Int(length)), as: UTF8.self)
        }
        for pattern in 0..<Int(ts_query_pattern_count(query)) {
            var count: UInt32 = 0
            guard let steps = ts_query_predicates_for_pattern(query, UInt32(pattern), &count), count > 0 else { continue }
            // 步骤序列:[字符串(谓词名), 参数…, Done] 重复
            var current: [(isCapture: Bool, value: UInt32)] = []
            var result: [TreeSitterPredicate] = []
            for index in 0..<Int(count) {
                let step = steps[index]
                if step.type == TSQueryPredicateStepTypeDone {
                    if let predicate = makePredicate(current, string: string) { result.append(predicate) }
                    current.removeAll()
                } else {
                    current.append((step.type == TSQueryPredicateStepTypeCapture, step.value_id))
                }
            }
            if !result.isEmpty { table[pattern] = result }
        }
        return table
    }

    /// 把一条谓词步骤翻译成可求值的形式;不认识的谓词忽略(视为通过)。
    private static func makePredicate(_ steps: [(isCapture: Bool, value: UInt32)], string: (UInt32) -> String) -> TreeSitterPredicate? {
        guard let first = steps.first, !first.isCapture else { return nil }
        let name = string(first.value)
        let args = Array(steps.dropFirst())
        switch name {
        case "eq?", "not-eq?", "any-eq?":
            guard args.count == 2, args[0].isCapture else { return nil }
            let negate = name == "not-eq?"
            if args[1].isCapture { return .equals(capture: args[0].value, otherCapture: args[1].value, literal: nil, negate: negate) }
            return .equals(capture: args[0].value, otherCapture: nil, literal: string(args[1].value), negate: negate)
        case "match?", "not-match?", "any-match?":
            guard args.count == 2, args[0].isCapture, !args[1].isCapture,
                  let regex = try? NSRegularExpression(pattern: string(args[1].value)) else { return nil }
            return .matches(capture: args[0].value, regex: regex, negate: name == "not-match?")
        case "any-of?", "not-any-of?":
            guard args.count >= 2, args[0].isCapture else { return nil }
            let values = Set(args.dropFirst().filter { !$0.isCapture }.map { string($0.value) })
            return .anyOf(capture: args[0].value, values: values, negate: name == "not-any-of?")
        default:
            return nil
        }
    }
}

/// 把 `.scm` 查询文本切成顶层模式(各自可独立编译)。
enum TreeSitterQuerySplitter {
    /// 切分查询源码。
    /// - Parameter source: 完整 `.scm` 文本
    /// - Returns: 顶层模式数组(含其后的 `@捕获`),不含注释
    static func split(_ source: String) -> [String] {
        let chars = Array(source.unicodeScalars)
        var patterns: [String] = []
        var current = String.UnicodeScalarView()
        var depth = 0
        var index = 0
        var inString = false
        /// 当前模式的主体已闭合,只允许接着出现量词与 `@捕获`
        var closed = false

        func flush() {
            let text = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { patterns.append(text) }
            current = String.UnicodeScalarView()
            closed = false
        }

        while index < chars.count {
            let char = chars[index]
            if inString {
                current.append(char)
                if char == "\\", index + 1 < chars.count { current.append(chars[index + 1]); index += 2; continue }
                if char == "\"" {
                    inString = false
                    if depth == 0 { closed = true }
                }
                index += 1
                continue
            }
            switch char {
            case ";":
                // 注释:跳到行尾
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            case "\"":
                if depth == 0, closed { flush() }
                inString = true
                current.append(char)
            case "(", "[":
                if depth == 0, closed { flush() }
                depth += 1
                current.append(char)
            case ")", "]":
                depth -= 1
                current.append(char)
                if depth <= 0 { depth = 0; closed = true }
            case "@":
                current.append(char)
                if depth == 0 {
                    // 吃掉捕获名
                    index += 1
                    while index < chars.count, !chars[index].properties.isWhitespace, chars[index] != "(", chars[index] != "[" {
                        current.append(chars[index])
                        index += 1
                    }
                    continue
                }
            default:
                if depth == 0, closed, !char.properties.isWhitespace, char != "?", char != "*", char != "+" { flush() }
                current.append(char)
            }
            index += 1
        }
        flush()
        return patterns
    }
}
