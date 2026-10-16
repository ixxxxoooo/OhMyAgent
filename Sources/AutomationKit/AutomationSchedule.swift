// @author ixxxxoooo
// 自动化调度:间隔 / 每日 / 每周 / cron 子集,含下一次触发时间计算与校验(纯逻辑,无副作用)。

import Foundation

/// 定时调度。
public enum AutomationSchedule: Codable, Hashable, Sendable {
    /// 每隔固定分钟数
    case interval(minutes: Int)
    /// 每天固定时刻
    case daily(hour: Int, minute: Int)
    /// 每周若干天的固定时刻(`weekdays` 采用 `Calendar` 的星期编号:1 = 周日 … 7 = 周六)
    case weekly(weekdays: [Int], hour: Int, minute: Int)
    /// 5 段 cron(分 时 日 月 周),支持 `*`、`*/n`、`a`、`a-b`、`a-b/n` 与逗号列表
    case cron(String)

    /// 间隔调度允许的最小分钟数(防止误填导致刷屏式触发)。
    public static let minimumIntervalMinutes = 5

    /// 计算严格晚于基准时间的下一次触发时间。
    /// - Parameters:
    ///   - base: 基准时间(上次运行或启用/编辑时间)
    ///   - calendar: 日历(测试可注入固定时区)
    /// - Returns: 下一次触发时间;cron 非法或一年内搜索不到时为 nil
    public func nextRun(after base: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let minutes):
            guard minutes >= 1 else { return nil }
            return base.addingTimeInterval(TimeInterval(minutes) * 60)
        case .daily(let hour, let minute):
            return Self.nextTime(hour: hour, minute: minute, weekdays: nil, after: base, calendar: calendar)
        case .weekly(let weekdays, let hour, let minute):
            guard !weekdays.isEmpty else { return nil }
            return Self.nextTime(hour: hour, minute: minute, weekdays: Set(weekdays), after: base, calendar: calendar)
        case .cron(let expression):
            guard let spec = CronSpec(expression) else { return nil }
            return spec.nextRun(after: base, calendar: calendar)
        }
    }

    /// 校验调度参数。
    /// - Returns: 错误提示;合法时为 nil
    public func validationMessage() -> String? {
        switch self {
        case .interval(let minutes):
            return minutes >= Self.minimumIntervalMinutes ? nil : String(localized: "间隔不能小于 \(Self.minimumIntervalMinutes) 分钟")
        case .daily(let hour, let minute):
            return Self.validTime(hour: hour, minute: minute) ? nil : String(localized: "时间不合法")
        case .weekly(let weekdays, let hour, let minute):
            if weekdays.isEmpty { return String(localized: "请至少选择一个星期") }
            if weekdays.contains(where: { !(1...7).contains($0) }) { return String(localized: "星期不合法") }
            return Self.validTime(hour: hour, minute: minute) ? nil : String(localized: "时间不合法")
        case .cron(let expression):
            return CronSpec(expression) == nil ? String(localized: "cron 表达式应为 5 段(分 时 日 月 周)") : nil
        }
    }

    /// 调度的人类可读描述,如「每 30 分钟」「每天 09:00」。
    /// - Parameter calendar: 日历(决定星期名称的语言)
    public func summary(calendar: Calendar = .current) -> String {
        switch self {
        case .interval(let minutes):
            return String(localized: "每 \(minutes) 分钟")
        case .daily(let hour, let minute):
            return String(localized: "每天 \(Self.timeText(hour: hour, minute: minute))")
        case .weekly(let weekdays, let hour, let minute):
            let names = weekdays.sorted().compactMap { day -> String? in
                let symbols = calendar.shortStandaloneWeekdaySymbols
                return (1...symbols.count).contains(day) ? symbols[day - 1] : nil
            }.joined(separator: "、")
            return String(localized: "每周 \(names) \(Self.timeText(hour: hour, minute: minute))")
        case .cron(let expression):
            return "cron " + expression
        }
    }

    /// 格式化为 `HH:mm`。
    public static func timeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func validTime(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// 从基准之后找出下一个满足「时刻 + 星期」的时间(最多向后看 8 天)。
    private static func nextTime(hour: Int, minute: Int, weekdays: Set<Int>?, after base: Date, calendar: Calendar) -> Date? {
        guard validTime(hour: hour, minute: minute) else { return nil }
        let startOfDay = calendar.startOfDay(for: base)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > base else { continue }
            if let weekdays, !weekdays.contains(calendar.component(.weekday, from: candidate)) { continue }
            return candidate
        }
        return nil
    }
}

/// 已解析的 cron 表达式(每个字段展开为允许取值的集合)。
struct CronSpec: Sendable, Equatable {
    var minutes: Set<Int>
    var hours: Set<Int>
    var daysOfMonth: Set<Int>
    var months: Set<Int>
    /// 星期取值 0...6(0 = 周日;输入的 7 视为周日)
    var weekdays: Set<Int>
    /// 日与星期是否都被限制(此时二者为「或」关系,与标准 cron 一致)
    var restrictsBothDayFields: Bool

    /// 解析 5 段表达式。
    /// - Parameter expression: 如 `0 9 * * 1-5`
    init?(_ expression: String) {
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5,
              let minutes = Self.expand(fields[0], range: 0...59),
              let hours = Self.expand(fields[1], range: 0...23),
              let days = Self.expand(fields[2], range: 1...31),
              let months = Self.expand(fields[3], range: 1...12),
              let weekdays = Self.expand(fields[4], range: 0...7)
        else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.daysOfMonth = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        self.restrictsBothDayFields = fields[2] != "*" && fields[4] != "*"
    }

    /// 展开单个字段为取值集合;任何一项非法则整体失败。
    private static func expand(_ field: String, range: ClosedRange<Int>) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let value = Int(pieces[1]), value >= 1 else { return nil }
                step = value
            }
            let base = String(pieces[0])
            var low = range.lowerBound
            var high = range.upperBound
            if base != "*" {
                let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count <= 2, let first = Int(bounds[0]) else { return nil }
                low = first
                if bounds.count == 2 {
                    guard let second = Int(bounds[1]) else { return nil }
                    high = second
                } else {
                    high = pieces.count == 2 ? range.upperBound : first
                }
            }
            guard range.contains(low), range.contains(high), low <= high else { return nil }
            for value in stride(from: low, through: high, by: step) { result.insert(value) }
        }
        return result.isEmpty ? nil : result
    }

    /// 日 / 星期两个字段是否匹配某一天。
    private func matchesDay(_ date: Date, calendar: Calendar) -> Bool {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date) - 1
        let dayOK = daysOfMonth.contains(day)
        let weekdayOK = weekdays.contains(weekday)
        return restrictsBothDayFields ? (dayOK || weekdayOK) : (dayOK && weekdayOK)
    }

    /// 严格晚于基准的下一次触发时间(最多向后看一年)。
    func nextRun(after base: Date, calendar: Calendar) -> Date? {
        let startOfDay = calendar.startOfDay(for: base)
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        for offset in 0...366 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            guard months.contains(calendar.component(.month, from: day)), matchesDay(day, calendar: calendar) else { continue }
            for hour in sortedHours {
                for minute in sortedMinutes {
                    if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), candidate > base {
                        return candidate
                    }
                }
            }
        }
        return nil
    }
}
