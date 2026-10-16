// @author ixxxxoooo
// 自动化中心:校验、到期判断(补跑一次)、并发上限、取消、超时、持久化与模板。

import Foundation
import Testing
@testable import AutomationKit

/// 可调的测试时钟。
@MainActor
final class TestClock {
    var current: Date
    init(_ date: Date) { current = date }
}

@MainActor
@Suite("自动化中心")
struct AutomationCenterTests {
    private func makeAutomation(_ name: String = "每日摘要", schedule: AutomationSchedule = .interval(minutes: 10), created: Date) -> Automation {
        Automation(name: name, prompt: "总结今天的改动", projectPath: "/tmp/demo", permissionMode: .readOnly, schedule: schedule, createdAt: created)
    }

    private func makeCenter(
        clock: TestClock, concurrent: Int = 2, timeout: Duration = .seconds(60),
        runner: @escaping @MainActor (AutomationRunRequest) async -> AutomationRunOutcome = { _ in AutomationRunOutcome(status: .succeeded, summary: "好") }
    ) -> (AutomationCenter, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oma-auto-\(UUID().uuidString)/automations.json")
        let center = AutomationCenter(fileURL: url, maxConcurrent: concurrent, runTimeout: timeout, calendar: utcCalendar(), now: { clock.current }, runner: runner)
        return (center, url)
    }

    /// 等待条件成立(最多 3 秒)。
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("表单校验:名称、提示词、项目、调度都要合法")
    func validation() {
        let good = makeAutomation(created: Date())
        #expect(good.validationMessage() == nil)
        var bad = good
        bad.name = "  "
        #expect(bad.validationMessage() != nil)
        bad = good; bad.prompt = ""
        #expect(bad.validationMessage() != nil)
        bad = good; bad.projectPath = ""
        #expect(bad.validationMessage() != nil)
        bad = good; bad.schedule = .interval(minutes: 1)
        #expect(bad.validationMessage() != nil)
        bad = good; bad.name = String(repeating: "长", count: Automation.maxNameLength + 1)
        #expect(bad.validationMessage() != nil)
    }

    @Test("到期判断:未到点不触发;错过多个周期只补跑一次")
    func dueAndCatchUpOnce() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock)
        await center.load()
        #expect(center.add(makeAutomation(created: clock.current)) == nil)
        clock.current = utcDate(2026, 10, 16, 8, 5)
        #expect(center.tick() == 0)
        // 应用「关闭」了一天:恢复后只补跑一次
        clock.current = utcDate(2026, 10, 17, 8, 0)
        #expect(center.tick() == 1)
        await waitUntil { center.runningIDs.isEmpty }
        #expect(center.library.runs.count == 1)
        #expect(center.tick() == 0)
        #expect(center.library.runs.first?.status == .succeeded)
        #expect(center.library.runs.first?.trigger == .schedule)
    }

    @Test("禁用的自动化不触发;重新启用不会立刻补跑陈年任务")
    func disabledAndReenable() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock)
        await center.load()
        let item = makeAutomation(created: clock.current)
        center.add(item)
        center.setEnabled(false, for: item.id)
        clock.current = utcDate(2026, 10, 20, 8, 0)
        #expect(center.tick() == 0)
        center.setEnabled(true, for: item.id)
        #expect(center.tick() == 0)
        clock.current = utcDate(2026, 10, 20, 8, 11)
        #expect(center.tick() == 1)
        await waitUntil { center.runningIDs.isEmpty }
    }

    @Test("并发上限:超出的任务留到下一个节拍")
    func concurrencyLimit() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock, concurrent: 1) { _ in
            try? await Task.sleep(for: .milliseconds(150))
            return AutomationRunOutcome(status: .succeeded, summary: "好")
        }
        await center.load()
        center.add(makeAutomation("甲", created: clock.current))
        center.add(makeAutomation("乙", created: clock.current))
        clock.current = utcDate(2026, 10, 16, 9, 0)
        #expect(center.tick() == 1)
        #expect(center.runningIDs.count == 1)
        await waitUntil { center.runningIDs.isEmpty }
        #expect(center.tick() == 1)
        await waitUntil { center.runningIDs.isEmpty }
        #expect(center.library.runs.count == 2)
    }

    @Test("手动运行:忽略调度,运行中重复触发被忽略")
    func manualRun() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock) { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return AutomationRunOutcome(status: .succeeded, summary: "好", sessionID: "s-1")
        }
        await center.load()
        let item = makeAutomation(created: clock.current)
        center.add(item)
        #expect(center.runNow(item.id))
        #expect(center.runNow(item.id) == false)
        await waitUntil { center.runningIDs.isEmpty }
        let run = center.library.runs(for: item.id).first
        #expect(run?.trigger == .manual)
        #expect(run?.sessionID == "s-1")
        #expect(center.runNow(UUID()) == false)
    }

    @Test("取消:执行器响应取消,记录为已取消")
    func cancellation() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock) { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { return AutomationRunOutcome(status: .failed, summary: "被打断") }
            return AutomationRunOutcome(status: .succeeded, summary: "好")
        }
        await center.load()
        let item = makeAutomation(created: clock.current)
        center.add(item)
        center.runNow(item.id)
        await waitUntil { center.currentRun(of: item.id) != nil }
        center.cancel(automation: item.id)
        await waitUntil { center.runningIDs.isEmpty }
        #expect(center.library.runs(for: item.id).first?.status == .cancelled)
    }

    @Test("超时:超过上限的运行被取消并记为已超时")
    func timeout() async {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, _) = makeCenter(clock: clock, timeout: .milliseconds(80)) { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { return AutomationRunOutcome(status: .failed, summary: "被打断") }
            return AutomationRunOutcome(status: .succeeded, summary: "好")
        }
        await center.load()
        let item = makeAutomation(created: clock.current)
        center.add(item)
        center.runNow(item.id)
        await waitUntil { center.runningIDs.isEmpty }
        #expect(center.library.runs(for: item.id).first?.status == .timedOut)
    }

    @Test("持久化往返;异常退出遗留的运行中记录被标记失败")
    func persistence() async throws {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, url) = makeCenter(clock: clock)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await center.load()
        let item = makeAutomation(created: clock.current)
        center.add(item)
        var stale = AutomationRun(automationID: item.id, trigger: .schedule, startedAt: clock.current)
        stale.status = .running
        center.testingInsert(run: stale)
        await center.flush()
        let reloaded = AutomationCenter(fileURL: url, calendar: utcCalendar(), now: { clock.current }, runner: { _ in AutomationRunOutcome(status: .succeeded, summary: "") })
        await reloaded.load()
        #expect(reloaded.library.automations.map(\.name) == ["每日摘要"])
        #expect(reloaded.library.runs.first?.status == .failed)
    }

    @Test("损坏的文件被备份,库重建为空")
    func corruptFile() async throws {
        let clock = TestClock(utcDate(2026, 10, 16, 8, 0))
        let (center, url) = makeCenter(clock: clock)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("不是 JSON".utf8).write(to: url)
        await center.load()
        #expect(center.isLoaded && center.library.automations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    @Test("运行记录按自动化裁剪;删除自动化同时删除记录")
    func runTrimming() {
        var library = AutomationLibrary()
        let id = UUID()
        for index in 0..<(AutomationLibrary.maxRunsPerAutomation + 5) {
            library.upsert(run: AutomationRun(automationID: id, trigger: .manual, startedAt: Date(timeIntervalSince1970: TimeInterval(index)), status: .succeeded))
        }
        #expect(library.runs(for: id).count == AutomationLibrary.maxRunsPerAutomation)
        #expect(library.runs(for: id).first?.startedAt == Date(timeIntervalSince1970: TimeInterval(AutomationLibrary.maxRunsPerAutomation + 4)))
        library.remove(automation: id)
        #expect(library.runs.isEmpty)
    }

    @Test("模板:全部合法且只读")
    func templates() {
        let templates = AutomationTemplate.all
        #expect(!templates.isEmpty)
        #expect(Set(templates.map(\.id)).count == templates.count)
        for template in templates {
            let automation = Automation(name: template.name, prompt: template.prompt, projectPath: "/tmp", permissionMode: template.permissionMode, schedule: template.schedule)
            #expect(automation.validationMessage() == nil, "模板不合法:\(template.id)")
            #expect(template.permissionMode == .readOnly)
        }
    }
}

@Suite("自动化表单草稿")
struct AutomationDraftTests {
    @Test("草稿与自动化互相转换且保留 ID")
    func roundTrip() {
        let original = Automation(name: "周报", prompt: "总结", projectPath: "/tmp/p", permissionMode: .acceptEdits, schedule: .weekly(weekdays: [2, 6], hour: 17, minute: 30))
        let draft = AutomationDraft(automation: original)
        #expect(draft.kind == .weekly && draft.hour == 17 && draft.minute == 30 && draft.weekdays == [2, 6])
        let rebuilt = draft.makeAutomation()
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.schedule == original.schedule)
        #expect(rebuilt.permissionMode == .acceptEdits)
    }

    @Test("切换调度类型后生成对应调度;非法内容校验失败")
    func scheduleKinds() {
        var draft = AutomationDraft()
        draft.name = "x"; draft.prompt = "y"; draft.projectPath = "/tmp"
        draft.kind = .interval; draft.intervalMinutes = 3
        #expect(draft.validationMessage() != nil)
        draft.intervalMinutes = 15
        #expect(draft.validationMessage() == nil)
        #expect(draft.schedule == .interval(minutes: 15))
        draft.kind = .cron; draft.cronExpression = " 0 9 * * * "
        #expect(draft.schedule == .cron("0 9 * * *"))
        draft.kind = .weekly; draft.weekdays = []
        #expect(draft.validationMessage() != nil)
    }

    @Test("模板生成草稿并带上项目目录")
    func fromTemplate() throws {
        let template = try #require(AutomationTemplate.all.first)
        let draft = AutomationDraft(template: template, projectPath: "/tmp/demo")
        #expect(draft.projectPath == "/tmp/demo")
        #expect(draft.name == template.name)
        #expect(draft.validationMessage() == nil)
    }
}
