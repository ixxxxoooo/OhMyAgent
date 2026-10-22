// @author ixxxxoooo
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
    /// 本地时间戳(毫秒精度),格式 `yyyy-MM-dd HH:mm:ss.SSS`。
    /// 用 `localtime_r` 手写拼装:线程安全且不创建 `DateFormatter`(其构造开销是日志热路径的主要成本)。
    public static func timestamp(_ date: Date) -> String {
        // 先四舍五入到整毫秒再拆分秒与毫秒,避免浮点截断少 1ms 或进位错误
        let totalMillis = Int((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = time_t(totalMillis >= 0 ? totalMillis / 1000 : (totalMillis - 999) / 1000)
        var parts = tm()
        localtime_r(&seconds, &parts)
        let millis = totalMillis - Int(seconds) * 1000
        var bytes = [UInt8](repeating: 0x30, count: 23)
        func put(_ value: Int, _ offset: Int, _ width: Int) {
            var rest = value
            var index = offset + width - 1
            while index >= offset {
                bytes[index] = UInt8(0x30 + rest % 10)
                rest /= 10
                index -= 1
            }
        }
        put(Int(parts.tm_year) + 1900, 0, 4); bytes[4] = 0x2D
        put(Int(parts.tm_mon) + 1, 5, 2); bytes[7] = 0x2D
        put(Int(parts.tm_mday), 8, 2); bytes[10] = 0x20
        put(Int(parts.tm_hour), 11, 2); bytes[13] = 0x3A
        put(Int(parts.tm_min), 14, 2); bytes[16] = 0x3A
        put(Int(parts.tm_sec), 17, 2); bytes[19] = 0x2E
        put(millis, 20, 3)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 本地日期 `yyyyMMdd`(用于日志文件名;同样不创建 `DateFormatter`)。
    public static func dayStamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        let year = Int(parts.tm_year) + 1900
        return String(format: "%04d%02d%02d", year, Int(parts.tm_mon) + 1, Int(parts.tm_mday))
    }

    /// 值中含空白/等号/引号时加引号,并转义换行,保证一条日志一行。
    public static func quote(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        let needs = flat.isEmpty || flat.contains(where: { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "\t" })
        return needs ? "\"" + flat.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : flat
    }
}
