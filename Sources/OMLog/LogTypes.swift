// @author ygw
// 日志基础类型:级别、分类、条目与行格式。

import Foundation

/// 日志级别(数值越大越严重)。
public enum LogLevel: Int, Sendable, Comparable, CaseIterable, Codable {
    case debug = 0, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 行格式中的固定宽度标签。
    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warning: return "WARN "
        case .error: return "ERROR"
        }
    }

    /// 从字符串解析(不区分大小写,支持 warn)。
    /// - Parameter text: 级别文本
    /// - Returns: 解析结果;无法识别返回 nil
    public init?(text: String) {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warning
        case "error": self = .error
        default: return nil
        }
    }
}

/// 日志分类(与 os.Logger 的 category 一一对应)。
public enum LogCategory: String, Sendable, CaseIterable, Codable {
    case app, acp, agent, session, tool, bridge, ui, editor, lsp, git, terminal, config, perf, update, log
}

/// 一条日志。
public struct LogEntry: Sendable, Hashable, Identifiable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    /// 附加键值(已脱敏),按键排序输出。
    public let fields: [String: String]
    /// 产生日志的进程名(主程序为 app)。
    public let process: String

    public init(id: UInt64, date: Date, level: LogLevel, category: LogCategory, message: String, fields: [String: String], process: String) {
        self.id = id; self.date = date; self.level = level; self.category = category
        self.message = message; self.fields = fields; self.process = process
    }

    /// 格式化为单行文本:`2026-10-16 02:50:01.123 INFO  [acp] 消息 key=value`。
    public var line: String {
        var text = "\(LogFormat.timestamp(date)) \(level.label) [\(category.rawValue)] \(message)"
        if !fields.isEmpty {
            text += " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(LogFormat.quote($0.value))" }.joined(separator: " ")
        }
        if process != "app" { text = "(\(process)) " + text }
        return text
    }
}

/// 行格式辅助。
public enum LogFormat {
    /// 本地时间戳(毫秒精度);每次新建格式化器以保证线程安全。
    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// 值中含空白/等号/引号时加引号,并转义换行,保证一条日志一行。
    public static func quote(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let needs = flat.isEmpty || flat.contains(where: { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "\t" })
        return needs ? "\"" + flat.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : flat
    }
}
