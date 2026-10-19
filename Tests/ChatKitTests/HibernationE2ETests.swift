// @author ixxxxoooo
// 休眠/唤醒端到端(真实 claude 适配器;只读恢复已有会话,不发提示词,不访问模型)。
// 默认跳过,需要 `OMA_E2E_SESSION=<会话ID>` 与 `OMA_E2E_CWD=<工作区>`。

import ACPKit
import AgentHost
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("休眠唤醒端到端", .enabled(if: ProcessInfo.processInfo.environment["OMA_E2E_SESSION"] != nil))
struct HibernationE2ETests {
    private func waitUntil(timeout: Double = 60, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// 本进程的后代里有多少个名为 claude / node 的进程。
    private func descendantProcessCount() -> Int {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var kids: [Int: [Int]] = [:]
        var names: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            kids[ppid, default: []].append(pid)
            names[pid] = String(parts[2])
        }
        var count = 0
        var stack = kids[Int(ProcessInfo.processInfo.processIdentifier)] ?? []
        while let pid = stack.popLast() {
            let name = (names[pid] ?? "").split(separator: "/").last.map(String.init) ?? ""
            if name == "claude" || name == "node" { count += 1 }
            stack.append(contentsOf: kids[pid] ?? [])
        }
        return count
    }

    @Test("回放已有会话 → 休眠(进程消失、内容保留)→ 唤醒(接回同一会话)")
    func hibernateAndWake() async throws {
        let env = ProcessInfo.processInfo.environment
        let sessionId = try #require(env["OMA_E2E_SESSION"])
        let cwd = env["OMA_E2E_CWD"] ?? FileManager.default.currentDirectoryPath
        let session = SessionModel(workspace: URL(fileURLWithPath: cwd))
        session.attention = AttentionCenter()
        session.prepareRestore(SessionSummary(sessionId: sessionId, cwd: cwd, title: nil))
        session.connect()
        #expect(await waitUntil { session.phase == .ready && !session.isReplaying && !session.timeline.entries.isEmpty })
        let entries = session.timeline.entries.count
        #expect(entries > 0)
        #expect(session.sessionId == sessionId)
        #expect(session.canHibernate)
        let liveProcesses = descendantProcessCount()
        #expect(liveProcesses >= 2)   // 适配器 + claude

        #expect(session.hibernate())
        #expect(session.isHibernated)
        #expect(session.phase == .idle)
        #expect(session.sessionId == sessionId)             // 会话 ID 保留(工作台据此持久化标签)
        #expect(session.timeline.entries.count == entries)   // 内容保留
        #expect(await waitUntil(timeout: 15) { descendantProcessCount() == 0 })

        session.wake()
        #expect(await waitUntil { session.phase == .ready && !session.isHibernated })
        #expect(session.sessionId == sessionId)             // 用 session/resume 接回同一会话
        #expect(session.timeline.entries.count == entries)   // 不回放、不重复
        #expect(descendantProcessCount() >= 2)
        session.shutdown()
        #expect(await waitUntil(timeout: 15) { descendantProcessCount() == 0 })
    }

    @Test("休眠中输入草稿会预唤醒")
    func draftPrewake() async throws {
        let env = ProcessInfo.processInfo.environment
        let sessionId = try #require(env["OMA_E2E_SESSION"])
        let cwd = env["OMA_E2E_CWD"] ?? FileManager.default.currentDirectoryPath
        let session = SessionModel(workspace: URL(fileURLWithPath: cwd))
        session.attention = AttentionCenter()
        session.prepareRestore(SessionSummary(sessionId: sessionId, cwd: cwd, title: nil))
        session.connect()
        #expect(await waitUntil { session.phase == .ready && !session.isReplaying })
        #expect(session.hibernate())
        session.draft = "h"
        #expect(await waitUntil { session.phase == .ready && !session.isHibernated })
        #expect(session.sessionId == sessionId)
        session.shutdown()
    }
}
