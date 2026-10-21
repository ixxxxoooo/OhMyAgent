// @author ixxxxoooo
// 问题(诊断)存储:按文件保存语言服务器上报的诊断,汇总错误/警告数量,供底部「问题」面板与状态栏使用。
// 无视图;偏移到行列的换算见 `IDELineMap`。

import Foundation
import Observation

/// 问题严重程度(与 LSP 一致,数值越小越严重)。
public enum IDESeverity: Int, Codable, Sendable, Comparable {
    case error = 1, warning, information, hint

    public static func < (lhs: IDESeverity, rhs: IDESeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 一条问题。
public struct IDEProblem: Identifiable, Equatable, Sendable {
    /// 文件绝对路径
    public var path: String
    /// 行号(1 起始)
    public var line: Int
    /// 列号(1 起始)
    public var column: Int
    public var severity: IDESeverity
    public var message: String

    public var id: String { "\(path):\(line):\(column):\(severity.rawValue):\(message)" }

    /// - Parameters:
    ///   - path: 文件绝对路径
    ///   - line: 行号(1 起始)
    ///   - column: 列号(1 起始)
    ///   - severity: 严重程度
    ///   - message: 文案
    public init(path: String, line: Int, column: Int, severity: IDESeverity, message: String) {
        self.path = path
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }
}

/// UTF-16 偏移 → 行列换算。
public enum IDELineMap {
    /// 把 UTF-16 偏移换算成 1 起始的行列。
    /// - Parameters:
    ///   - offset: UTF-16 偏移(越界会被钳制)
    ///   - text: 文本
    /// - Returns: (行, 列),均从 1 开始
    public static func lineColumn(utf16Offset offset: Int, in text: String) -> (line: Int, column: Int) {
        let units = text.utf16
        let target = max(0, min(offset, units.count))
        var line = 1
        var lineStart = 0
        var index = 0
        for unit in units {
            if index >= target { break }
            index += 1
            if unit == 10 { line += 1; lineStart = index }
        }
        return (line, target - lineStart + 1)
    }
}

/// 一个窗口的问题存储。
@MainActor
@Observable
public final class ProblemsStore {
    /// 文件 → 问题(按行列排序)
    public private(set) var byFile: [String: [IDEProblem]] = [:]

    public init() {}

    /// 替换某文件的全部问题;空数组等同于清除。
    /// - Parameters:
    ///   - problems: 该文件当前的问题
    ///   - path: 文件路径
    public func set(_ problems: [IDEProblem], forFile path: String) {
        guard !path.isEmpty else { return }
        let sorted = problems.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
        if sorted.isEmpty {
            if byFile[path] != nil { byFile[path] = nil }
        } else if byFile[path] != sorted {
            byFile[path] = sorted
        }
    }

    /// 清除某文件的问题。
    /// - Parameter path: 文件路径
    public func clear(file path: String) { set([], forFile: path) }

    /// 错误数量。
    public var errorCount: Int { count(.error) }
    /// 警告数量。
    public var warningCount: Int { count(.warning) }
    /// 全部问题数量。
    public var totalCount: Int { byFile.values.reduce(0) { $0 + $1.count } }

    /// 文件按路径排序后的问题分组。
    public var groups: [(path: String, problems: [IDEProblem])] {
        byFile.keys.sorted().map { ($0, byFile[$0] ?? []) }
    }

    /// 指定严重程度以上(含)的问题。
    /// - Parameter minimum: 最低严重程度(默认全部)
    public func problems(atLeast minimum: IDESeverity = .hint) -> [IDEProblem] {
        groups.flatMap(\.problems).filter { $0.severity <= minimum }
    }

    private func count(_ severity: IDESeverity) -> Int {
        byFile.values.reduce(0) { $0 + $1.filter { $0.severity == severity }.count }
    }
}
