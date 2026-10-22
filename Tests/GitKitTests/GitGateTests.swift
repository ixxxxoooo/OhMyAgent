// @author ixxxxoooo
// git 仓库级闸门:并发上限、相同只读命令合并、写命令使旧读取不再被合并、排队可取消;索引刷新节流。

import Foundation
import Synchronization
import Testing
@testable import GitKit

/// 并发计数器(记录同时在跑的最大数量)。
private final class Probe: Sendable {
    private let state = Mutex((current: 0, peak: 0, runs: 0))
    func enter() { state.withLock { $0.current += 1; $0.runs += 1; $0.peak = max($0.peak, $0.current) } }
    func leave() { state.withLock { $0.current -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
    var runs: Int { state.withLock { $0.runs } }
}

private func output(_ text: String = "") -> GitOutput { GitOutput(status: 0, stdout: Data(text.utf8), stderr: "") }

@Suite("git 仓库级闸门")
struct GitGateTests {
    @Test("同一仓库同时最多 2 个进程,其余排队,全部完成")
    func concurrencyLimit() async throws {
        let gate = GitGate(limit: 2)
        let probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await gate.run(root: "/repo", dedupeKey: nil) {
                        probe.enter(); defer { probe.leave() }
                        try await Task.sleep(for: .milliseconds(30))
                        return output()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.peak <= 2 && probe.peak >= 1)
        #expect(probe.runs == 8)
        #expect(await gate.runningCount(root: "/repo") == 0)
    }

    @Test("不同仓库互不占用名额")
    func perRepositoryLimit() async throws {
        let gate = GitGate(limit: 1)
        let probe = Probe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for root in ["/a", "/b", "/c"] {
                group.addTask {
                    _ = try await gate.run(root: root, dedupeKey: nil) {
                        probe.enter(); defer { probe.leave() }
                        try await Task.sleep(for: .milliseconds(80))
                        return output()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.peak == 3, "三个仓库各占一个名额,可同时运行")
    }

    @Test("并发的相同只读命令合并为一次执行")
    func dedupe() async throws {
        let gate = GitGate(limit: 2)
        let probe = Probe()
        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 {
                group.addTask {
                    try await gate.run(root: "/repo", dedupeKey: "status") {
                        probe.enter(); defer { probe.leave() }
                        try await Task.sleep(for: .milliseconds(80))
                        return output("ok")
                    }.text
                }
            }
            var all: [String] = []
            for try await value in group { all.append(value) }
            return all
        }
        #expect(results == Array(repeating: "ok", count: 5))
        #expect(probe.runs == 1)
        #expect(await gate.mergedCount == 4)
    }

    @Test("写命令之后的读取不会合并进写之前开始的读取")
    func writeInvalidatesInflightReads() async throws {
        let gate = GitGate(limit: 2)
        let probe = Probe()
        async let first = gate.run(root: "/repo", dedupeKey: "status") {
            probe.enter(); defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(150))
            return output("old")
        }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await gate.run(root: "/repo", dedupeKey: nil) { output("write") }
        let after = try await gate.run(root: "/repo", dedupeKey: "status") { output("new") }
        #expect(after.text == "new", "写之后的读取要重新执行")
        #expect(try await first.text == "old")
    }

    @Test("排队中的任务被取消时立即退出且不占名额")
    func cancelledWaiterLeavesQueue() async throws {
        let gate = GitGate(limit: 1)
        let holder = Task { try await gate.run(root: "/repo", dedupeKey: nil) { try await Task.sleep(for: .milliseconds(200)); return output() } }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task { try await gate.run(root: "/repo", dedupeKey: nil) { output("never") } }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        let result = await waiter.result
        if case .success = result { Issue.record("被取消的排队任务不应执行") }
        _ = try await holder.value
        #expect(await gate.runningCount(root: "/repo") == 0)
        // 之后仍可正常获取名额
        let next = try await gate.run(root: "/repo", dedupeKey: nil) { output("fine") }
        #expect(next.text == "fine")
    }
}

@Suite("git 索引刷新节流")
struct GitIndexRefreshTests {
    @Test("同一仓库在间隔内只放行一次带锁刷新,过了间隔再放行")
    func throttled() {
        let root = "/throttle-\(UUID().uuidString)"
        let start = ContinuousClock.now
        #expect(GitRepository.claimIndexRefresh(root: root, now: start))
        #expect(!GitRepository.claimIndexRefresh(root: root, now: start.advanced(by: .seconds(10))))
        #expect(!GitRepository.claimIndexRefresh(root: root, now: start.advanced(by: .seconds(60))))
        #expect(GitRepository.claimIndexRefresh(root: root, now: start.advanced(by: GitRepository.indexRefreshInterval + .seconds(1))))
        #expect(GitRepository.claimIndexRefresh(root: root + "-other", now: start), "不同仓库互不影响")
    }
}
