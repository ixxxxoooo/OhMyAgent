// @author ixxxxoooo
// 单元格数字格式:把 xlsx 里的数值按其数字格式(常规/小数/千分位/百分比/科学计数/日期时间)转成显示文本。
// 只覆盖日常表格最常见的格式,不实现完整的 Excel 格式语言。

import Foundation

/// 一种数字显示样式。
public enum CellNumberStyle: Equatable, Sendable {
    /// 常规
    case general
    /// 固定小数位(可选千分位与百分号)
    case fixed(decimals: Int, thousands: Bool, percent: Bool)
    /// 科学计数
    case scientific(decimals: Int)
    /// 日期/时间
    case date(hasDate: Bool, hasTime: Bool)
    /// 文本(按原文显示)
    case text
}

/// 数字格式解析与格式化。
public enum CellFormat {
    /// 解析某个数字格式。
    /// - Parameters:
    ///   - id: 内置格式编号
    ///   - code: 自定义格式串(内置格式为 nil)
    /// - Returns: 显示样式
    public static func style(id: Int, code: String?) -> CellNumberStyle {
        if let code, !code.isEmpty { return style(forCode: code) }
        switch id {
        case 0: return .general
        case 1: return .fixed(decimals: 0, thousands: false, percent: false)
        case 2: return .fixed(decimals: 2, thousands: false, percent: false)
        case 3: return .fixed(decimals: 0, thousands: true, percent: false)
        case 4: return .fixed(decimals: 2, thousands: true, percent: false)
        case 9: return .fixed(decimals: 0, thousands: false, percent: true)
        case 10: return .fixed(decimals: 2, thousands: false, percent: true)
        case 11: return .scientific(decimals: 2)
        case 14...17: return .date(hasDate: true, hasTime: false)
        case 18...21, 45...47: return .date(hasDate: false, hasTime: true)
        case 22: return .date(hasDate: true, hasTime: true)
        case 37, 38: return .fixed(decimals: 0, thousands: true, percent: false)
        case 39, 40: return .fixed(decimals: 2, thousands: true, percent: false)
        case 49: return .text
        default: return .general
        }
    }

    /// 解析自定义格式串(只看第一段,即正数格式)。
    static func style(forCode raw: String) -> CellNumberStyle {
        // 去掉引号字面量、转义字符与颜色/条件方括号(保留 [h]/[m]/[s] 经过时间)
        var code = ""
        var inQuote = false
        var inBracket = false
        var bracket = ""
        var escaped = false
        for ch in raw {
            if escaped { escaped = false; continue }
            if ch == "\\" || ch == "_" || ch == "*" { escaped = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "[" { inBracket = true; bracket = ""; continue }
            if ch == "]" {
                inBracket = false
                if ["h", "hh", "m", "mm", "s", "ss"].contains(bracket.lowercased()) { code += bracket.lowercased() }
                continue
            }
            if inBracket { bracket.append(ch); continue }
            if ch == ";" { break }
            code.append(ch)
        }
        let lower = code.lowercased()
        if lower == "general" || lower.isEmpty { return .general }
        if lower == "@" { return .text }
        // 科学计数:0.00E+00
        if lower.contains("e+") || lower.contains("e-") {
            return .scientific(decimals: decimals(in: lower))
        }
        // 日期时间:出现 y/d/h/s,或 m 与其它日期字段共存(单独的 0.0 之类不会含这些字母)
        let hasDate = lower.contains("y") || lower.contains("d")
        let hasTime = lower.contains("h") || lower.contains("s") || lower.contains("am/pm")
        if hasDate || hasTime || (lower.contains("m") && !lower.contains("0") && !lower.contains("#")) {
            return .date(hasDate: hasDate, hasTime: hasTime)
        }
        let percent = lower.contains("%")
        let thousands = lower.contains("#,#") || lower.contains("0,0") || lower.contains("#,0")
        return .fixed(decimals: decimals(in: lower), thousands: thousands, percent: percent)
    }

    /// 小数点之后的占位符个数。
    private static func decimals(in code: String) -> Int {
        guard let dot = code.firstIndex(of: ".") else { return 0 }
        var count = 0
        for ch in code[code.index(after: dot)...] {
            if ch == "0" || ch == "#" || ch == "?" { count += 1 } else { break }
        }
        return count
    }

    // MARK: 格式化

    /// 把数值按样式转成显示文本。
    /// - Parameters:
    ///   - value: 数值
    ///   - style: 样式
    ///   - date1904: 工作簿是否使用 1904 日期系统
    public static func format(_ value: Double, style: CellNumberStyle, date1904: Bool = false) -> String {
        guard value.isFinite else { return "#NUM!" }
        switch style {
        case .general, .text:
            return general(value)
        case .fixed(let decimals, let thousands, let percent):
            let scaled = percent ? value * 100 : value
            var text = String(format: "%.\(decimals)f", abs(scaled))
            if thousands { text = groupThousands(text) }
            if percent { text += "%" }
            // 四舍五入后为 0 的负数不显示负号
            let isZero = Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")) == 0
            return (scaled < 0 && !isZero ? "-" : "") + text
        case .scientific(let decimals):
            return String(format: "%.\(decimals)E", value)
        case .date(let hasDate, let hasTime):
            return date(serial: value, hasDate: hasDate, hasTime: hasTime, date1904: date1904)
        }
    }

    /// 常规格式:整数不带小数点;其余最多 15 位有效数字。
    static func general(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    /// 给整数部分加千分位逗号。
    private static func groupThousands(_ text: String) -> String {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = Array(parts[0])
        var grouped = ""
        for (offset, ch) in integer.enumerated() {
            if offset > 0, (integer.count - offset) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        return parts.count > 1 ? grouped + "." + parts[1] : grouped
    }

    /// Excel 序列号 → `yyyy-MM-dd` / `HH:mm:ss` 文本(不依赖 DateFormatter,批量转换足够快)。
    static func date(serial: Double, hasDate: Bool, hasTime: Bool, date1904: Bool) -> String {
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 { seconds -= 86_400; days += 1 }
        var parts: [String] = []
        if hasDate {
            // 自 1970-01-01 起的天数。1900 系统:序列号 25569 = 1970-01-01,且 Excel 误把 1900 当闰年(序列号 60 不存在),
            // 所以 60 以前的序列号要多加一天;1904 系统:序列号 24107 = 1970-01-01
            let unixDays: Int
            if date1904 {
                unixDays = days - 24_107
            } else {
                unixDays = (days < 60 ? days + 1 : days) - 25_569
            }
            let day = civilDate(fromUnixDays: unixDays)
            parts.append(String(format: "%04d-%02d-%02d", day.year, day.month, day.day))
        }
        // 只有日期格式但带有时间小数时也补上时间,避免信息丢失
        if hasTime || !hasDate || seconds != 0 {
            parts.append(String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60))
        }
        return parts.joined(separator: " ")
    }

    /// 自 1970-01-01 起的天数 → 公历日期(Howard Hinnant 的 civil_from_days 算法)。
    private static func civilDate(fromUnixDays z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
