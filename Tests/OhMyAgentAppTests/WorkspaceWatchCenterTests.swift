// @author ixxxxoooo
// 工作区监听中心:切换监听范围后,已打开标签的变化跟随不能失效。

import Foundation
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("工作区监听中心", .serialized)
struct WorkspaceWatchCenterTests {
    /// 回调计数器。
    @MainActor
    final class Counter {
        var value = 0
    }

    @Test("切换项目后旧项目的文件改为轮询,仍能收到检查")
    func followSurvivesRootSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oma-watch-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a").path
        let b = base.appendingPathComponent("b").path
        try FileManager.default.createDirectory(atPath: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = a + "/f.txt"
        try Data("1".utf8).write(to: URL(fileURLWithPath: file))

        let center = WorkspaceWatchCenter()
        center.watch(root: a)
        #expect(center.covers(file))
        let counter = Counter()
        let task = Task { @MainActor in
            await center.follow(file, poll: .milliseconds(50)) { counter.value += 1 }
        }
        try await Task.sleep(for: .milliseconds(100))
        let before = counter.value
        center.watch(root: b)
        #expect(!center.covers(file))
        // 订阅结束补查一次,之后按轮询间隔持续检查
        let deadline = ContinuousClock.now + .seconds(10)
        while counter.value < before + 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(counter.value >= before + 3)
        task.cancel()
        center.watch(root: nil)
    }

    @Test("项目被监听覆盖时由事件驱动刷新,空闲不轮询;未覆盖时按间隔轮询")
    func followProjectIsEventDriven() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oma-watch-proj-\(UUID().uuidString)")
        let project = base.appendingPathComponent("p").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // 事件回调固定投递给共享实例,所以这里用共享实例
        let center = WorkspaceWatchCenter.shared
        center.watch(root: nil)
        // 未覆盖:轮询
        #expect(!center.coversRoot(project))
        let polled = Counter()
        let pollTask = Task { @MainActor in
            await center.followProject(project, poll: .milliseconds(30)) { polled.value += 1 }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while polled.value < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(polled.value >= 3)
        pollTask.cancel()

        // 覆盖:空闲时不回调(兜底间隔设得很长),文件改动后收到事件刷新
        center.watch(root: project)
        #expect(center.coversRoot(project))
        let driven = Counter()
        let task = Task { @MainActor in
            await center.followProject(project, poll: .milliseconds(30), safety: .seconds(60), debounce: .milliseconds(20), minInterval: .zero) { driven.value += 1 }
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(driven.value == 0, "空闲时不应有刷新")
        try Data("x".utf8).write(to: URL(fileURLWithPath: project + "/new.txt"))
        let wait = ContinuousClock.now + .seconds(10)
        while driven.value == 0, ContinuousClock.now < wait { try await Task.sleep(for: .milliseconds(30)) }
        #expect(driven.value >= 1, "文件变化后应收到事件刷新")
        task.cancel()
        center.watch(root: nil)
    }
}
