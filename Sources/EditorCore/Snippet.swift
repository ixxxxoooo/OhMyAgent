// @author ixxxxoooo
// Snippet 引擎(兼容 VS Code 语法):`$1`、`${1:默认值}`、`${1|a,b,c|}`、`$0`、镜像占位、`$变量`/`${变量:默认}`、转义。
// 解析与渲染是纯函数;会话 `SnippetSession` 负责在编辑中追踪各占位区间并在 Tab 间切换。

import Foundation

/// 解析得到的占位点(同一编号的多处出现为镜像)。
public struct SnippetStop: Sendable, Equatable {
    /// 编号;0 为最终光标位置。
    public var index: Int
    /// 各处出现的区间(相对 snippet 文本起点的 UTF-16 区间),第一项为主占位。
    public var ranges: [TextSpan]
    /// 选项列表(`${1|a,b|}`),无则为 nil。
    public var choices: [String]?

    public init(index: Int, ranges: [TextSpan], choices: [String]? = nil) {
        self.index = index
        self.ranges = ranges
        self.choices = choices
    }
}

/// 展开后的 snippet。
public struct ParsedSnippet: Sendable, Equatable {
    /// 插入的纯文本。
    public var text: String
    /// 占位点,按 Tab 顺序排列:1、2、…,最后是 0(无 `$0` 时补在文末)。
    public var stops: [SnippetStop]
}

/// Snippet 解析器。
public enum SnippetParser {
    /// 语法树节点。
    private indirect enum Node {
        case text(String)
        case tabstop(index: Int, children: [Node], choices: [String]?)
        case variable(name: String, children: [Node])
    }

    /// 解析 snippet 源文本。
    /// - Parameters:
    ///   - source: 含 `$` 语法的源文本
    ///   - variables: 变量取值(如 `TM_FILENAME`);未提供的变量用默认值或变量名
    /// - Returns: 展开结果
    public static func parse(_ source: String, variables: [String: String] = [:]) -> ParsedSnippet {
        var scanner = Lexer(Array(source.unicodeScalars))
        let nodes = scanner.parseNodes(stopAtBrace: false)
        // 收集每个编号第一个非空默认值,供镜像使用。
        var defaults: [Int: String] = [:]
        collectDefaults(nodes, into: &defaults, variables: variables)
        var output = ""
        var length = 0
        var ranges: [Int: [TextSpan]] = [:]
        var choices: [Int: [String]] = [:]
        render(nodes, defaults: defaults, variables: variables, output: &output, length: &length,
               ranges: &ranges, choices: &choices, plainOnly: false)
        var stops = ranges.keys.filter { $0 != 0 }.sorted().map { SnippetStop(index: $0, ranges: ranges[$0] ?? [], choices: choices[$0]) }
        let final = ranges[0] ?? [TextSpan(location: length, length: 0)]
        stops.append(SnippetStop(index: 0, ranges: final))
        return ParsedSnippet(text: output, stops: stops)
    }

    // MARK: 渲染

    private static func plainText(_ nodes: [Node], defaults: [Int: String], variables: [String: String]) -> String {
        var output = ""
        var length = 0
        var ranges: [Int: [TextSpan]] = [:]
        var choices: [Int: [String]] = [:]
        render(nodes, defaults: defaults, variables: variables, output: &output, length: &length,
               ranges: &ranges, choices: &choices, plainOnly: true)
        return output
    }

    private static func collectDefaults(_ nodes: [Node], into defaults: inout [Int: String], variables: [String: String]) {
        for node in nodes {
            switch node {
            case .text: break
            case .tabstop(let index, let children, let choices):
                let text = choices?.first ?? plainText(children, defaults: defaults, variables: variables)
                if !text.isEmpty, defaults[index] == nil { defaults[index] = text }
                collectDefaults(children, into: &defaults, variables: variables)
            case .variable(_, let children):
                collectDefaults(children, into: &defaults, variables: variables)
            }
        }
    }

    private static func render(
        _ nodes: [Node], defaults: [Int: String], variables: [String: String],
        output: inout String, length: inout Int,
        ranges: inout [Int: [TextSpan]], choices: inout [Int: [String]], plainOnly: Bool
    ) {
        func append(_ text: String) { output += text; length += text.utf16.count }
        for node in nodes {
            switch node {
            case .text(let text):
                append(text)
            case .tabstop(let index, let children, let options):
                let start = length
                if let first = options?.first {
                    append(first)
                    if !plainOnly { choices[index] = options }
                } else if children.isEmpty {
                    append(defaults[index] ?? "")
                } else {
                    render(children, defaults: defaults, variables: variables, output: &output, length: &length,
                           ranges: &ranges, choices: &choices, plainOnly: plainOnly)
                }
                if !plainOnly { ranges[index, default: []].append(TextSpan(lower: start, upper: length)) }
            case .variable(let name, let children):
                if let value = variables[name] {
                    append(value)
                } else if children.isEmpty {
                    append(name)
                } else {
                    render(children, defaults: defaults, variables: variables, output: &output, length: &length,
                           ranges: &ranges, choices: &choices, plainOnly: plainOnly)
                }
            }
        }
    }

    // MARK: 词法/语法

    private struct Lexer {
        let scalars: [Unicode.Scalar]
        var position = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { position >= scalars.count }
        func peek(_ offset: Int = 0) -> Unicode.Scalar? { position + offset < scalars.count ? scalars[position + offset] : nil }

        /// 解析一串节点;`stopAtBrace` 时遇到未转义的 `}` 停止(不消费)。
        mutating func parseNodes(stopAtBrace: Bool) -> [Node] {
            var nodes: [Node] = []
            var buffer = String.UnicodeScalarView()
            func flush() { if !buffer.isEmpty { nodes.append(.text(String(buffer))); buffer = String.UnicodeScalarView() } }
            while let scalar = peek() {
                if scalar == "}" && stopAtBrace { break }
                if scalar == "\\", let next = peek(1), next == "$" || next == "}" || next == "\\" {
                    buffer.append(next)
                    position += 2
                    continue
                }
                if scalar == "$", let node = parseDollar() {
                    flush()
                    nodes.append(node)
                    continue
                }
                buffer.append(scalar)
                position += 1
            }
            flush()
            return nodes
        }

        /// 解析以 `$` 开头的结构;不合法时返回 nil(`$` 当普通字符)。
        mutating func parseDollar() -> Node? {
            let saved = position
            position += 1
            guard let next = peek() else { position = saved; return nil }
            if next.isASCII, Int(String(next)) != nil {
                return .tabstop(index: readInt(), children: [], choices: nil)
            }
            if isIdentStart(next) {
                return .variable(name: readIdent(), children: [])
            }
            if next == "{" {
                position += 1
                if let first = peek(), first.isASCII, Int(String(first)) != nil {
                    let index = readInt()
                    if peek() == "}" { position += 1; return .tabstop(index: index, children: [], choices: nil) }
                    if peek() == ":" {
                        position += 1
                        let children = parseNodes(stopAtBrace: true)
                        if peek() == "}" { position += 1 }
                        return .tabstop(index: index, children: children, choices: nil)
                    }
                    if peek() == "|" {
                        position += 1
                        var options: [String] = []
                        var current = String.UnicodeScalarView()
                        while let scalar = peek() {
                            if scalar == "\\", let escaped = peek(1) { current.append(escaped); position += 2; continue }
                            if scalar == "," { options.append(String(current)); current = String.UnicodeScalarView(); position += 1; continue }
                            if scalar == "|" { position += 1; break }
                            current.append(scalar)
                            position += 1
                        }
                        options.append(String(current))
                        if peek() == "}" { position += 1 }
                        return .tabstop(index: index, children: [], choices: options)
                    }
                    position = saved
                    return nil
                }
                if let first = peek(), isIdentStart(first) {
                    let name = readIdent()
                    if peek() == "}" { position += 1; return .variable(name: name, children: []) }
                    if peek() == ":" {
                        position += 1
                        let children = parseNodes(stopAtBrace: true)
                        if peek() == "}" { position += 1 }
                        return .variable(name: name, children: children)
                    }
                }
            }
            position = saved
            return nil
        }

        func isIdentStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || (scalar.isASCII && scalar.properties.isAlphabetic)
        }

        mutating func readInt() -> Int {
            var value = 0
            while let scalar = peek(), scalar.isASCII, let digit = Int(String(scalar)) {
                value = value * 10 + digit
                position += 1
            }
            return value
        }

        mutating func readIdent() -> String {
            var name = String.UnicodeScalarView()
            while let scalar = peek(), scalar == "_" || (scalar.isASCII && (scalar.properties.isAlphabetic || Int(String(scalar)) != nil)) {
                name.append(scalar)
                position += 1
            }
            return String(name)
        }
    }
}

/// 活动 snippet 会话:追踪各占位在文档中的绝对区间。
public struct SnippetSession: Sendable, Equatable {
    /// 占位点(绝对偏移区间)。
    public private(set) var stops: [SnippetStop]
    /// 当前占位在 `stops` 中的下标。
    public private(set) var current: Int

    /// 创建会话。
    /// - Parameters:
    ///   - snippet: 已解析 snippet
    ///   - origin: snippet 文本插入的起点偏移
    public init(snippet: ParsedSnippet, origin: Int) {
        stops = snippet.stops.map { stop in
            SnippetStop(index: stop.index,
                        ranges: stop.ranges.map { TextSpan(location: $0.location + origin, length: $0.length) },
                        choices: stop.choices)
        }
        current = 0
    }

    /// 当前占位点。
    public var currentStop: SnippetStop { stops[current] }

    /// 是否在最终位置 `$0`。
    public var isAtFinalStop: Bool { stops[current].index == 0 }

    /// 前进到下一个占位;已在最后一个时返回 false。
    public mutating func advance() -> Bool {
        guard current + 1 < stops.count else { return false }
        current += 1
        return true
    }

    /// 回到上一个占位;已在第一个时返回 false。
    public mutating func retreat() -> Bool {
        guard current > 0 else { return false }
        current -= 1
        return true
    }

    /// 经过一批编辑后更新所有占位区间。起点向左、终点向右映射,使占位在其内部键入时自然增长。
    public mutating func map(through edits: [AppliedEdit]) {
        for stopIndex in stops.indices {
            stops[stopIndex].ranges = stops[stopIndex].ranges.map { range in
                let start = OffsetMapping.map(range.location, through: edits, bias: .left)
                let end = OffsetMapping.map(range.upperBound, through: edits, bias: .right)
                return TextSpan(lower: start, upper: max(start, end))
            }
        }
    }

    /// 所有占位区间(含镜像),用于装饰。
    public var allRanges: [(range: TextSpan, isCurrent: Bool)] {
        var result: [(TextSpan, Bool)] = []
        for (index, stop) in stops.enumerated() {
            for range in stop.ranges { result.append((range, index == current)) }
        }
        return result
    }
}
