// @author ixxxxoooo
// MermaidKit 入口:识别图类型 → 解析 → 布局 → 场景。

import CoreGraphics
import Foundation

/// Mermaid 图类型。
public enum MermaidKind: String, Sendable {
    case flowchart, state, classDiagram, sequence, pie, gantt
}

public enum Mermaid {
    /// 识别图类型。
    /// - Returns: 图类型;不支持时抛出 `MermaidError`。
    public static func kind(of source: String) throws -> MermaidKind {
        let first = cleanedLines(source).first?.lowercased() ?? ""
        if first.hasPrefix("graph") || first.hasPrefix("flowchart") { return .flowchart }
        if first.hasPrefix("statediagram") { return .state }
        if first.hasPrefix("classdiagram") { return .classDiagram }
        if first.hasPrefix("sequencediagram") { return .sequence }
        if first.hasPrefix("pie") { return .pie }
        if first.hasPrefix("gantt") { return .gantt }
        let word = first.split(separator: " ").first.map(String.init) ?? ""
        throw MermaidError(word.isEmpty ? String(localized: "内容为空") : String(localized: "暂不支持的图类型:\(word)"))
    }

    /// 解析并布局,生成可绘制的场景。
    /// - Parameter source: Mermaid 源码(不含围栏)
    /// - Throws: `MermaidError`(含行号)
    public static func scene(for source: String) throws -> MScene {
        let lines = cleanedLines(source)
        switch try kind(of: source) {
        case .flowchart: return FlowLayout.scene(for: try FlowchartParser.parse(lines))
        case .state: return FlowLayout.scene(for: try StateParser.parse(lines))
        case .classDiagram: return FlowLayout.scene(for: try ClassParser.parse(lines))
        case .sequence: return SequenceLayout.scene(for: try SequenceParser.parse(lines))
        case .pie: return PieLayout.scene(for: try PieParser.parse(lines))
        case .gantt: return GanttLayout.scene(for: try GanttParser.parse(lines))
        }
    }

    /// 去掉 YAML 头、`%%{init}%%` 指令与空行,返回以图类型声明开头的行集合。
    static func cleanedLines(_ source: String) -> [String] {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) { lines.removeSubrange(0...end) }
        }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%{") }
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty || f.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { lines.removeFirst() }
        return lines
    }
}
