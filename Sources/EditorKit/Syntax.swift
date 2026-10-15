// @author ygw
// 轻量词法高亮:后台一次性扫描整个文件,按视口增量应用。

import Foundation

/// 支持的语言。
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, javascript, typescript, python, json, markdown, shell, rust, go, java, c, yaml, plain

    /// 根据文件扩展名推断语言。
    /// - Parameter path: 文件路径或文件名
    /// - Returns: 推断结果,未知返回 `.plain`
    public static func detect(path: String) -> SyntaxLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "py": return .python
        case "json", "jsonc": return .json
        case "md", "markdown": return .markdown
        case "sh", "zsh", "bash": return .shell
        case "rs": return .rust
        case "go": return .go
        case "java", "kt": return .java
        case "c", "h", "cpp", "hpp", "cc", "m", "mm": return .c
        case "yml", "yaml", "toml": return .yaml
        default: return .plain
        }
    }

    /// 关键字集合。
    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .javascript, .typescript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return", "then", "while"]
        case .rust:
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .go:
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
        case .java:
            return ["abstract", "boolean", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "new", "null", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "throws", "true", "try", "void", "while", "fun", "val", "var"]
        case .c:
            return ["auto", "break", "case", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "nullptr", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "typedef", "union", "unsigned", "using", "void", "volatile", "while", "true", "false"]
        case .json, .yaml:
            return ["true", "false", "null"]
        case .markdown, .plain:
            return []
        }
    }

    /// 是否使用 `//` 行注释。
    var slashComments: Bool {
        switch self {
        case .swift, .javascript, .typescript, .rust, .go, .java, .c: return true
        default: return false
        }
    }

    /// 是否使用 `#` 行注释。
    var hashComments: Bool {
        switch self {
        case .python, .shell, .yaml: return true
        default: return false
        }
    }

    /// 是否支持 `/* */` 块注释。
    var blockComments: Bool { slashComments }
}

/// 词法类别。
public enum SyntaxKind: UInt8, Sendable {
    case keyword, string, comment, number, type, function, property
}

/// 一个高亮片段(UTF-16 范围)。
public struct SyntaxSpan: Sendable, Equatable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind
}

/// 词法扫描器。输出按起点升序、互不重叠的片段。
public enum SimpleLexer {
    /// 对文本做全量词法扫描。
    /// - Parameters:
    ///   - text: 文本
    ///   - language: 语言
    /// - Returns: 片段数组
    public static func lex(_ text: String, language: SyntaxLanguage) -> [SyntaxSpan] {
        if language == .plain { return [] }
        let units = Array(text.utf16)
        let count = units.count
        var spans: [SyntaxSpan] = []
        spans.reserveCapacity(count / 8)
        let keywords = language.keywords
        var i = 0

        @inline(__always) func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
        }
        @inline(__always) func isIdentPart(_ c: UInt16) -> Bool {
            isIdentStart(c) || (c >= 0x30 && c <= 0x39)
        }
        @inline(__always) func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

        while i < count {
            let c = units[i]
            // 行注释
            if language.slashComments, c == 0x2F, i + 1 < count, units[i + 1] == 0x2F {
                let start = i
                while i < count, units[i] != 0x0A { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .comment))
                continue
            }
            if language.hashComments, c == 0x23 {
                let start = i
                while i < count, units[i] != 0x0A { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .comment))
                continue
            }
            // 块注释
            if language.blockComments, c == 0x2F, i + 1 < count, units[i + 1] == 0x2A {
                let start = i
                i += 2
                while i + 1 < count, !(units[i] == 0x2A && units[i + 1] == 0x2F) { i += 1 }
                i = min(i + 2, count)
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .comment))
                continue
            }
            // 字符串
            if c == 0x22 || c == 0x27 || c == 0x60 {
                if language == .rust && c == 0x27 { i += 1; continue }
                let quote = c
                let start = i
                i += 1
                while i < count {
                    if units[i] == 0x5C { i += 2; continue }
                    if units[i] == quote { i += 1; break }
                    if units[i] == 0x0A && quote != 0x60 { break }
                    i += 1
                }
                i = min(i, count)
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .string))
                continue
            }
            // 数字
            if isDigit(c) {
                let start = i
                while i < count, isDigit(units[i]) || units[i] == 0x2E || units[i] == 0x5F || isIdentPart(units[i]) { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .number))
                continue
            }
            // 标识符
            if isIdentStart(c) {
                let start = i
                while i < count, isIdentPart(units[i]) { i += 1 }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                if keywords.contains(word) {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .keyword))
                } else if i < count, units[i] == 0x28, language != .json, language != .markdown {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .function))
                } else if units[start] >= 0x41 && units[start] <= 0x5A, language != .json, language != .shell {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .type))
                } else if start > 0, units[start - 1] == 0x2E {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .property))
                }
                continue
            }
            i += 1
        }
        return spans
    }

    /// 二分查找:返回第一个与 `location` 之后相交的片段下标。
    /// - Parameters:
    ///   - spans: 有序片段
    ///   - location: 起点
    /// - Returns: 下标
    public static func firstIndex(in spans: [SyntaxSpan], endingAfter location: Int) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].location + spans[mid].length <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// 高亮引擎:在后台 actor 内完成扫描并缓存结果。
public actor HighlightEngine {
    private var spans: [SyntaxSpan] = []

    public init() {}

    /// 重新扫描整个文本。
    /// - Parameters:
    ///   - text: 文本
    ///   - language: 语言
    /// - Returns: 扫描得到的片段数
    @discardableResult
    public func rebuild(text: String, language: SyntaxLanguage) -> Int {
        spans = SimpleLexer.lex(text, language: language)
        return spans.count
    }

    /// 取与范围相交的片段。
    /// - Parameter range: UTF-16 范围
    /// - Returns: 片段数组
    public func spans(in range: NSRange) -> [SyntaxSpan] {
        let start = SimpleLexer.firstIndex(in: spans, endingAfter: range.location)
        var result: [SyntaxSpan] = []
        var index = start
        let end = range.location + range.length
        while index < spans.count, spans[index].location < end {
            result.append(spans[index])
            index += 1
        }
        return result
    }
}
