// @author ixxxxoooo
// 自动化调度计算:间隔 / 每日 / 每周 / cron 子集的下一次触发、校验与描述。

import Foundation
import Testing
@testable import AutomationKit

/// 固定为 UTC 的日历,避免测试依赖本机时区。
func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}

/// 构造 UTC 时间。
func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return utcCalendar().date(from: components) ?? Date(timeIntervalSince1970: 0)
}

@Suite("自动化调度")
struct AutomationScheduleTests {
    private let calendar = utcCalendar()

    @Test("间隔调度:基准之后固定分钟数,小于 5 分钟校验失败")
    func interval() {
        let base = utcDate(2026, 10, 16, 8, 0)
        #expect(AutomationSchedule.interval(minutes: 30).nextRun(after: base, calendar: calendar) == utcDate(2026, 10, 16, 8, 30))
        #expect(AutomationSchedule.interval(minutes: 4).validationMessage() != nil)
        #expect(AutomationSchedule.interval(minutes: 5).validationMessage() == nil)
    }

    @Test("每日调度:今天未到点取今天,已过点取明天,严格晚于基准")
    func daily() {
        let schedule = AutomationSchedule.daily(hour: 9, minute: 0)
        #expect(schedule.nextRun(after: utcDate(2026, 10, 16, 8, 59), calendar: calendar) == utcDate(2026, 10, 16, 9, 0))
        #expect(schedule.nextRun(after: utcDate(2026, 10, 16, 9, 0), calendar: calendar) == utcDate(2026, 10, 17, 9, 0))
        #expect(AutomationSchedule.daily(hour: 25, minute: 0).validationMessage() != nil)
        #expect(AutomationSchedule.daily(hour: 25, minute: 0).nextRun(after: Date(), calendar: calendar) == nil)
    }

    @Test("每周调度:只在选中的星期触发(2026-10-16 是周五)")
    func weekly() {
        // 周一(2)与周五(6)的 10:00
        let schedule = AutomationSchedule.weekly(weekdays: [2, 6], hour: 10, minute: 0)
        #expect(schedule.nextRun(after: utcDate(2026, 10, 16, 9, 0), calendar: calendar) == utcDate(2026, 10, 16, 10, 0))
        #expect(schedule.nextRun(after: utcDate(2026, 10, 16, 10, 0), calendar: calendar) == utcDate(2026, 10, 19, 10, 0))
        #expect(AutomationSchedule.weekly(weekdays: [], hour: 1, minute: 0).validationMessage() != nil)
        #expect(AutomationSchedule.weekly(weekdays: [8], hour: 1, minute: 0).validationMessage() != nil)
    }

    @Test("cron:工作日 9 点、步长、列表与范围")
    func cron() {
        let weekdays = AutomationSchedule.cron("0 9 * * 1-5")
        // 周五 9:00 之后 → 下周一 9:00
        #expect(weekdays.nextRun(after: utcDate(2026, 10, 16, 9, 0), calendar: calendar) == utcDate(2026, 10, 19, 9, 0))
        let step = AutomationSchedule.cron("*/15 * * * *")
        #expect(step.nextRun(after: utcDate(2026, 10, 16, 8, 1), calendar: calendar) == utcDate(2026, 10, 16, 8, 15))
        let list = AutomationSchedule.cron("0 8,20 * * *")
        #expect(list.nextRun(after: utcDate(2026, 10, 16, 8, 0), calendar: calendar) == utcDate(2026, 10, 16, 20, 0))
        // 星期 7 等价周日
        let sunday = AutomationSchedule.cron("0 0 * * 7")
        #expect(sunday.nextRun(after: utcDate(2026, 10, 16), calendar: calendar) == utcDate(2026, 10, 18))
    }

    @Test("cron:日与星期都限制时取「或」,非法表达式被拒绝")
    func cronEdgeCases() {
        // 每月 20 日 或 周一
        let either = AutomationSchedule.cron("0 0 20 * 1")
        #expect(either.nextRun(after: utcDate(2026, 10, 16), calendar: calendar) == utcDate(2026, 10, 19))
        for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "*/0 * * * *", "a b c d e", "5-1 * * * *", "* * * * * *"] {
            #expect(AutomationSchedule.cron(bad).validationMessage() != nil, "应拒绝:\(bad)")
            #expect(AutomationSchedule.cron(bad).nextRun(after: Date(), calendar: calendar) == nil)
        }
    }

    @Test("描述文案:间隔、每日、cron")
    func summaries() {
        #expect(AutomationSchedule.daily(hour: 9, minute: 5).summary(calendar: calendar).contains("09:05"))
        #expect(AutomationSchedule.interval(minutes: 30).summary(calendar: calendar).contains("30"))
        #expect(AutomationSchedule.cron("0 9 * * 1-5").summary(calendar: calendar) == "cron 0 9 * * 1-5")
    }

    @Test("调度可编码往返")
    func codable() throws {
        let values: [AutomationSchedule] = [.interval(minutes: 10), .daily(hour: 1, minute: 2), .weekly(weekdays: [2, 3], hour: 4, minute: 5), .cron("0 9 * * *")]
        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(AutomationSchedule.self, from: data) == value)
        }
    }
}
