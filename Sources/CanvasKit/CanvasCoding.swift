// @author ixxxxoooo
// Canvas 块的宽松 JSON 编解码与校验:模型生成的 JSON 常见「数字写成字符串/字符串写成数字」,
// 这里统一容忍;真正无法修复的问题给出带路径的中文错误,方便模型据此重试。

import Foundation

/// 画布解析/校验错误(描述面向模型,中文)。
public struct CanvasError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - 宽松解码辅助

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init(_ name: String) { self.stringValue = name }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

/// 宽松字符串:接受字符串、数字、布尔,null 视为空串。
private struct Loose: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { value = ""; return }
        if let text = try? single.decode(String.self) { value = text; return }
        if let number = try? single.decode(Int.self) { value = String(number); return }
        if let number = try? single.decode(Double.self) { value = Self.format(number); return }
        if let flag = try? single.decode(Bool.self) { value = flag ? "true" : "false"; return }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "需要字符串或数字"))
    }

    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}

/// 宽松数字:接受数字或可解析的字符串(如 "12.5"、"1,200")。
private struct LooseNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let number = try? single.decode(Double.self) { value = number; return }
        if let text = try? single.decode(String.self), let number = Double(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) {
            value = number
            return
        }
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "需要数字"))
    }
}

private extension KeyedDecodingContainer where Key == DynamicKey {
    func key(_ name: String) -> DynamicKey { DynamicKey(name) }

    /// 依次尝试多个别名取字符串。
    func string(_ names: String...) throws -> String? {
        for name in names where contains(key(name)) {
            if try decodeNil(forKey: key(name)) { continue }
            return try decode(Loose.self, forKey: key(name)).value
        }
        return nil
    }

    func strings(_ name: String) throws -> [String] {
        guard contains(key(name)), try !decodeNil(forKey: key(name)) else { return [] }
        return try decode([Loose].self, forKey: key(name)).map(\.value)
    }

    func bool(_ name: String) -> Bool? { try? decodeIfPresent(Bool.self, forKey: key(name)) }

    func int(_ name: String) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key(name)) { return value }
        return (try? decodeIfPresent(Loose.self, forKey: key(name)))?.flatMap { Int($0.value) }
    }
}

// MARK: - 统计项

extension CanvasStat {
    /// 宽松解码一项统计。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        guard let label = try c.string("label", "title", "name"), !label.isEmpty else {
            throw DecodingError.keyNotFound(c.key("label"), .init(codingPath: decoder.codingPath, debugDescription: "统计项缺少 label"))
        }
        self.label = label
        self.value = try c.string("value") ?? ""
        let delta = try c.string("delta", "change")
        self.delta = (delta?.isEmpty ?? true) ? nil : delta
        self.tone = (try c.string("tone")).flatMap(CanvasTone.init(rawValue:)) ?? .neutral
    }
}

// MARK: - 块

extension CanvasBlock: Codable {
    /// 宽松解码(按 `type` 分派)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        guard let type = try c.string("type")?.lowercased() else {
            throw DecodingError.keyNotFound(c.key("type"), .init(codingPath: decoder.codingPath, debugDescription: "缺少 type 字段"))
        }
        switch type {
        case "heading", "title":
            self = .heading(text: try c.string("text", "title") ?? "", level: min(max(c.int("level") ?? 2, 1), 3))
        case "markdown", "text", "paragraph":
            self = .markdown(try c.string("text", "content", "markdown") ?? "")
        case "stats", "metrics":
            let items = try c.decode([CanvasStat].self, forKey: c.key("items"))
            self = .stats(items)
        case "table":
            let columns = try c.strings("columns")
            var rows: [[String]] = []
            if c.contains(c.key("rows")) {
                let raw = try c.decode([[Loose]].self, forKey: c.key("rows"))
                rows = raw.map { $0.map(\.value) }
            }
            self = .table(CanvasTable(columns: columns, rows: rows, title: try c.string("title")))
        case "chart":
            let kindText = try c.string("kind", "chart", "variant") ?? "bar"
            guard let kind = CanvasChartKind(rawValue: kindText.lowercased()) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [c.key("kind")], debugDescription: "图表类型必须是 bar/line/area/pie,收到 \(kindText)"))
            }
            let labels = try c.strings("labels")
            var series: [CanvasSeries] = []
            if c.contains(c.key("series")) {
                var list = try c.nestedUnkeyedContainer(forKey: c.key("series"))
                while !list.isAtEnd {
                    let item = try list.nestedContainer(keyedBy: DynamicKey.self)
                    let name = try item.string("name", "label") ?? ""
                    let values = try item.decode([LooseNumber].self, forKey: item.key("values")).map(\.value)
                    series.append(CanvasSeries(name: name, values: values))
                }
            }
            self = .chart(CanvasChart(kind: kind, title: try c.string("title"), labels: labels, series: series))
        case "callout", "note", "alert":
            let tone = (try c.string("tone", "kind")).flatMap(CanvasTone.init(rawValue:)) ?? .info
            self = .callout(tone: tone, title: try c.string("title"), text: try c.string("text", "content") ?? "")
        case "code":
            self = .code(language: try c.string("language", "lang"), text: try c.string("text", "code", "content") ?? "")
        case "image":
            guard let source = try c.string("source", "path", "url", "src"), !source.isEmpty else {
                throw DecodingError.keyNotFound(c.key("source"), .init(codingPath: decoder.codingPath, debugDescription: "图片缺少 source(本机路径或 http(s) 地址)"))
            }
            self = .image(source: source, caption: try c.string("caption", "alt"))
        case "mermaid":
            self = .mermaid(try c.string("text", "source", "code") ?? "")
        case "section", "group":
            let children = c.contains(c.key("blocks")) ? try c.decode([CanvasBlock].self, forKey: c.key("blocks")) : []
            self = .section(title: try c.string("title") ?? "", collapsed: c.bool("collapsed") ?? false, blocks: children)
        case "divider", "hr":
            self = .divider
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [c.key("type")],
                                                    debugDescription: "未知块类型 \(type);可用:heading markdown stats table chart callout code image mermaid section divider"))
        }
    }

    /// 规范化编码(稳定字段名)。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        func put<T: Encodable>(_ name: String, _ value: T) throws { try c.encode(value, forKey: DynamicKey(name)) }
        try put("type", typeName)
        switch self {
        case .heading(let text, let level): try put("text", text); try put("level", level)
        case .markdown(let text): try put("text", text)
        case .stats(let items): try put("items", items.map(StatDTO.init))
        case .table(let table):
            try put("columns", table.columns); try put("rows", table.rows)
            if let title = table.title { try put("title", title) }
        case .chart(let chart):
            try put("kind", chart.kind.rawValue); try put("labels", chart.labels)
            try put("series", chart.series.map { SeriesDTO(name: $0.name, values: $0.values) })
            if let title = chart.title { try put("title", title) }
        case .callout(let tone, let title, let text):
            try put("tone", tone.rawValue); try put("text", text)
            if let title { try put("title", title) }
        case .code(let language, let text):
            try put("text", text)
            if let language { try put("language", language) }
        case .image(let source, let caption):
            try put("source", source)
            if let caption { try put("caption", caption) }
        case .mermaid(let text): try put("text", text)
        case .section(let title, let collapsed, let blocks):
            try put("title", title); try put("collapsed", collapsed); try put("blocks", blocks)
        case .divider: break
        }
    }

    private struct StatDTO: Encodable {
        var label: String
        var value: String
        var delta: String?
        var tone: String
        init(_ stat: CanvasStat) { label = stat.label; value = stat.value; delta = stat.delta; tone = stat.tone.rawValue }
    }

    private struct SeriesDTO: Encodable {
        var name: String
        var values: [Double]
    }
}

// MARK: - 解析与校验

public enum CanvasParser {
    /// 把 JSON 数组(块列表)解析并校验为块。
    /// - Parameter data: JSON 数据(`[ {type:...}, ... ]`)
    /// - Returns: 规范化后的块
    /// - Throws: `CanvasError`(带路径的中文说明)
    public static func parseBlocks(_ data: Data) throws -> [CanvasBlock] {
        let decoded: [CanvasBlock]
        do {
            decoded = try JSONDecoder().decode([CanvasBlock].self, from: data)
        } catch let error as DecodingError {
            throw CanvasError(describe(error))
        } catch {
            throw CanvasError("blocks 不是合法的 JSON 数组:\(error.localizedDescription)")
        }
        return try validate(decoded)
    }

    /// 把单个图表的 JSON 对象(会话里 ```chart 围栏的内容)解析为图表;`type` 缺省视为 chart。
    /// - Parameter data: JSON 对象:`{kind, title?, labels, series:[{name, values}]}`
    /// - Returns: 校验后的图表
    /// - Throws: `CanvasError`(带路径的中文说明);非对象或非图表块同样报错
    public static func parseChart(_ data: Data) throws -> CanvasChart {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CanvasError("图表内容不是合法的 JSON 对象")
        }
        if object["type"] == nil { object["type"] = "chart" }
        let wrapped = try JSONSerialization.data(withJSONObject: [object])
        guard case .chart(let chart)? = try parseBlocks(wrapped).first else { throw CanvasError("内容不是图表") }
        return chart
    }

    /// 校验并规范化块列表(表格行补齐/截断,图表校验等长,规模上限)。
    /// - Parameter blocks: 待校验的块
    /// - Returns: 规范化后的块
    /// - Throws: `CanvasError`
    public static func validate(_ blocks: [CanvasBlock]) throws -> [CanvasBlock] {
        let total = blocks.reduce(0) { $0 + $1.totalCount }
        guard total <= CanvasLimits.maxBlocks else { throw CanvasError("块太多(\(total) > \(CanvasLimits.maxBlocks)),请精简或拆成多个画布") }
        return try blocks.enumerated().map { try normalize($1, path: "blocks[\($0)]", depth: 1) }
    }

    private static func normalize(_ block: CanvasBlock, path: String, depth: Int) throws -> CanvasBlock {
        func checkLength(_ text: String, _ field: String) throws {
            if text.count > CanvasLimits.maxTextLength { throw CanvasError("\(path).\(field) 过长(上限 \(CanvasLimits.maxTextLength) 字符)") }
        }
        switch block {
        case .markdown(let text): try checkLength(text, "text"); return block
        case .code(_, let text): try checkLength(text, "text"); return block
        case .mermaid(let text):
            try checkLength(text, "text")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CanvasError("\(path) 的 mermaid 源码为空") }
            return block
        case .stats(let items):
            if items.isEmpty { throw CanvasError("\(path).items 不能为空") }
            return block
        case .table(var table):
            guard !table.columns.isEmpty else { throw CanvasError("\(path).columns 不能为空") }
            guard table.columns.count <= CanvasLimits.maxTableColumns else { throw CanvasError("\(path) 列数过多(上限 \(CanvasLimits.maxTableColumns))") }
            guard table.rows.count <= CanvasLimits.maxTableRows else { throw CanvasError("\(path) 行数过多(上限 \(CanvasLimits.maxTableRows))") }
            let width = table.columns.count
            table.rows = table.rows.map { row in
                row.count == width ? row : Array(row.prefix(width)) + Array(repeating: "", count: max(0, width - row.count))
            }
            return .table(table)
        case .chart(let chart):
            guard !chart.labels.isEmpty, !chart.series.isEmpty else { throw CanvasError("\(path) 图表需要非空的 labels 与 series") }
            guard chart.pointCount <= CanvasLimits.maxChartPoints else { throw CanvasError("\(path) 数据点过多(上限 \(CanvasLimits.maxChartPoints))") }
            for (index, series) in chart.series.enumerated() where series.values.count != chart.labels.count {
                throw CanvasError("\(path).series[\(index)].values 数量(\(series.values.count))必须与 labels(\(chart.labels.count))一致")
            }
            if chart.kind == .pie, chart.series.count != 1 { throw CanvasError("\(path) 饼图只能有 1 个系列") }
            return block
        case .image(let source, _):
            let lower = source.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || source.hasPrefix("/") || source.hasPrefix("~") || !source.contains("://") else {
                throw CanvasError("\(path).source 只支持本机路径或 http(s) 地址")
            }
            return block
        case .section(let title, let collapsed, let children):
            guard depth < CanvasLimits.maxDepth else { throw CanvasError("\(path) 分区嵌套过深(上限 \(CanvasLimits.maxDepth) 层)") }
            let normalized = try children.enumerated().map { try normalize($1, path: "\(path).blocks[\($0)]", depth: depth + 1) }
            return .section(title: title, collapsed: collapsed, blocks: normalized)
        case .heading, .callout, .divider:
            return block
        }
    }

    /// 把 DecodingError 翻译成带路径的中文说明。
    static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            var text = "blocks"
            for key in codingPath {
                if let index = key.intValue { text += "[\(index)]" } else { text += "." + key.stringValue }
            }
            return text
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])) 缺失:\(context.debugDescription)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context.codingPath)) 无效:\(context.debugDescription)"
        @unknown default:
            return "blocks 解析失败:\(error.localizedDescription)"
        }
    }
}
