// @author ygw
// 轻量词法高亮:后台一次性扫描整个文件,按视口增量应用。

import Foundation

/// 支持的语言。
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case swift, javascript, typescript, python, json, markdown, shell, rust, go, java, c, yaml, plain
    case html, css, sql, ruby, php, lua, toml, dockerfile

    /// 根据文件扩展名推断语言。
    /// - Parameter path: 文件路径或文件名
    /// - Returns: 推断结果,未知返回 `.plain`
    public static func detect(path: String) -> SyntaxLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return .dockerfile }
        if name == "makefile" || name == "gnumakefile" { return .shell }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi": return .python
        case "json", "jsonc", "json5": return .json
        case "md", "markdown", "mdx": return .markdown
        case "sh", "zsh", "bash": return .shell
        case "rs": return .rust
        case "go": return .go
        case "java", "kt", "kts", "scala", "dart", "cs": return .java
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "m", "mm": return .c
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf", "properties": return .toml
        case "html", "htm", "xhtml", "xml", "svg", "plist", "xib", "storyboard", "vue", "xsd", "xsl": return .html
        case "css", "scss", "less", "sass": return .css
        case "sql": return .sql
        case "rb", "rake", "gemspec": return .ruby
        case "php": return .php
        case "lua": return .lua
        default: return .plain
        }
    }

    /// 根据 Markdown 围栏的语言标签(如 `ts`、`sh`、`yml`)推断语言。
    /// - Parameter fence: 围栏信息串(可空,可含附加参数如 `swift title=x`)
    /// - Returns: 推断结果,未知返回 `.plain`
    public static func fromFence(_ fence: String?) -> SyntaxLanguage {
        guard let raw = fence?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .plain }
        let name = raw.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? raw
        switch name {
        case "swift": return .swift
        case "js", "javascript", "jsx", "node", "mjs", "cjs": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python", "python3": return .python
        case "json", "jsonc", "json5": return .json
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh", "shell", "console", "terminal", "fish": return .shell
        case "rs", "rust": return .rust
        case "go", "golang": return .go
        case "java", "kotlin", "kt", "scala", "dart", "csharp", "cs": return .java
        case "c", "cpp", "c++", "cc", "h", "hpp", "objc", "objective-c", "objectivec", "m", "mm": return .c
        case "yaml", "yml": return .yaml
        case "toml", "ini", "conf", "properties": return .toml
        case "html", "xml", "svg", "xhtml", "vue", "plist": return .html
        case "css", "scss", "less", "sass": return .css
        case "sql", "mysql", "postgres", "postgresql", "sqlite", "pgsql": return .sql
        case "ruby", "rb": return .ruby
        case "php": return .php
        case "lua": return .lua
        case "dockerfile", "docker": return .dockerfile
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
        case .toml:
            return ["true", "false"]
        case .sql:
            return ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "view", "join", "left", "right", "inner", "outer", "full", "cross", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "between", "exists", "union", "all", "distinct", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default", "unique", "constraint", "check", "begin", "commit", "rollback", "transaction", "true", "false", "asc", "desc", "with", "returning", "truncate", "database", "schema", "if", "add", "column", "cascade", "grant", "revoke", "explain"]
        case .ruby:
            return ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "include", "extend", "attr_accessor", "attr_reader", "attr_writer", "lambda", "proc", "puts"]
        case .php:
            return ["abstract", "and", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "empty", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "null", "or", "print", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield"]
        case .lua:
            return ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]
        case .dockerfile:
            return ["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS", "MAINTAINER"]
        case .markdown, .plain, .html, .css:
            return []
        }
    }

    /// 是否使用 `//` 行注释。
    var slashComments: Bool {
        switch self {
        case .swift, .javascript, .typescript, .rust, .go, .java, .c, .php: return true
        default: return false
        }
    }

    /// 是否使用 `#` 行注释。
    var hashComments: Bool {
        switch self {
        case .python, .shell, .yaml, .ruby, .php, .toml, .dockerfile: return true
        default: return false
        }
    }

    /// 是否使用 `--` 行注释。
    var dashComments: Bool { self == .sql || self == .lua }

    /// 关键字是否忽略大小写(SQL)。
    var caseInsensitiveKeywords: Bool { self == .sql }

    /// 是否支持 `/* */` 块注释。
    var blockComments: Bool { slashComments || self == .sql }
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
        if language == .html { return lexMarkup(Array(text.utf16)) }
        if language == .css { return lexCSS(Array(text.utf16)) }
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
            if language.dashComments, c == 0x2D, i + 1 < count, units[i + 1] == 0x2D {
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
                if keywords.contains(language.caseInsensitiveKeywords ? word.lowercased() : word) {
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

    // MARK: HTML / XML

    /// 标记语言扫描:注释、标签名(关键字色)、属性名、引号字符串、实体。
    private static func lexMarkup(_ units: [UInt16]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        let count = units.count
        var i = 0
        func isNameChar(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x3A || c == 0x2E
        }
        func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func matches(_ text: String, at index: Int) -> Bool {
            var j = index
            for u in text.utf16 {
                guard j < count, units[j] == u else { return false }
                j += 1
            }
            return true
        }
        while i < count {
            if units[i] == 0x3C { // <
                if matches("<!--", at: i) {
                    let start = i
                    i += 4
                    while i < count, !matches("-->", at: i) { i += 1 }
                    i = min(i + 3, count)
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .comment))
                    continue
                }
                var j = i + 1
                if j < count, units[j] == 0x2F || units[j] == 0x21 || units[j] == 0x3F { j += 1 }
                guard j < count, isLetter(units[j]) || units[j - 1] == 0x21 || units[j - 1] == 0x3F else { i += 1; continue }
                while j < count, isNameChar(units[j]) { j += 1 }
                spans.append(SyntaxSpan(location: i, length: j - i, kind: .keyword))
                i = j
                // 标签内部:属性与字符串直到 >
                while i < count, units[i] != 0x3E {
                    let c = units[i]
                    if c == 0x22 || c == 0x27 {
                        let start = i
                        i += 1
                        while i < count, units[i] != c { i += 1 }
                        i = min(i + 1, count)
                        spans.append(SyntaxSpan(location: start, length: i - start, kind: .string))
                    } else if isLetter(c) {
                        let start = i
                        while i < count, isNameChar(units[i]) { i += 1 }
                        spans.append(SyntaxSpan(location: start, length: i - start, kind: .property))
                    } else {
                        i += 1
                    }
                }
                if i < count { i += 1 }
                continue
            }
            if units[i] == 0x26 { // & 实体
                var j = i + 1
                while j < count, j - i < 10, isNameChar(units[j]) || units[j] == 0x23 { j += 1 }
                if j < count, units[j] == 0x3B {
                    spans.append(SyntaxSpan(location: i, length: j + 1 - i, kind: .number))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return spans
    }

    // MARK: CSS

    /// 样式表扫描:注释、字符串、at 规则、选择器(类型色)、属性名、数值与颜色、函数。
    private static func lexCSS(_ units: [UInt16]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        let count = units.count
        var i = 0
        var depth = 0
        func isIdentChar(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c > 0x7F
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F || c > 0x7F }
        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        while i < count {
            let c = units[i]
            if c == 0x2F, i + 1 < count, units[i + 1] == 0x2A {
                let start = i
                i += 2
                while i + 1 < count, !(units[i] == 0x2A && units[i + 1] == 0x2F) { i += 1 }
                i = min(i + 2, count)
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .comment))
            } else if c == 0x22 || c == 0x27 {
                let start = i
                i += 1
                while i < count, units[i] != c, units[i] != 0x0A { i += units[i] == 0x5C ? 2 : 1 }
                i = min(i + 1, count)
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .string))
            } else if c == 0x7B { depth += 1; i += 1
            } else if c == 0x7D { depth = max(depth - 1, 0); i += 1
            } else if c == 0x40, i + 1 < count, isIdentStart(units[i + 1]) {
                let start = i
                i += 1
                while i < count, isIdentChar(units[i]) { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .keyword))
            } else if c == 0x23, i + 1 < count, isHex(units[i + 1]), depth > 0 {
                let start = i
                i += 1
                while i < count, isHex(units[i]) { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .number))
            } else if (c == 0x23 || c == 0x2E), depth == 0, i + 1 < count, isIdentStart(units[i + 1]) {
                let start = i
                i += 1
                while i < count, isIdentChar(units[i]) { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .type))
            } else if isDigit(c) || (c == 0x2E && i + 1 < count && isDigit(units[i + 1]) && depth > 0) {
                let start = i
                while i < count, isDigit(units[i]) || units[i] == 0x2E { i += 1 }
                while i < count, (units[i] >= 0x61 && units[i] <= 0x7A) || (units[i] >= 0x41 && units[i] <= 0x5A) || units[i] == 0x25 { i += 1 }
                spans.append(SyntaxSpan(location: start, length: i - start, kind: .number))
            } else if isIdentStart(c) {
                let start = i
                while i < count, isIdentChar(units[i]) { i += 1 }
                var j = i
                while j < count, units[j] == 0x20 || units[j] == 0x09 { j += 1 }
                if depth == 0 {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .type))
                } else if j < count, units[j] == 0x3A, !(j + 1 < count && units[j + 1] == 0x3A) {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .property))
                } else if i < count, units[i] == 0x28 {
                    spans.append(SyntaxSpan(location: start, length: i - start, kind: .function))
                }
            } else {
                i += 1
            }
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
