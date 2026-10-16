// @author ygw
// 演示场景目录测试:每个场景都能在内存传输上跑通;冻结态可被取消;ID 唯一;覆盖守卫。

import Foundation
import Testing
@testable import ACPKit

/// 自动选择第一个「允许」选项的委托(找不到则拒绝)。
final class AllowFirstDelegate: ACPClientDelegate, @unchecked Sendable {
    func requestPermission(_ request: PermissionRequest) async -> PermissionOutcome {
        if let option = request.options.first(where: { $0.kind == .allowOnce || $0.kind == .allowAlways }) {
            return .selected(optionId: option.optionId)
        }
        return .cancelled
    }

    func createTerminal(sessionId: String, command: String, args: [String], env: [String: String], cwd: String?, outputByteLimit: Int?) async throws -> String { "fake-terminal" }
    func waitForTerminalExit(terminalId: String) async throws -> TerminalOutputSnapshot { TerminalOutputSnapshot(output: "done", exitCode: 0) }
}

/// 跨并发域传递结束原因的盒子(测试内顺序读写)。
final class StopBox: @unchecked Sendable { var value: StopReason = .endTurn }

/// 运行一个提示并收集全部会话更新。
private func runPrompt(_ text: String, delegate: ACPClientDelegate = AllowFirstDelegate(), cwd: String = NSTemporaryDirectory(), delay: Int = 1) async throws -> (stop: StopReason, updates: [SessionUpdate]) {
    let (a, b) = LoopbackTransport.makePair()
    let agent = ScriptedAgent(transport: b, chunkDelayMillis: delay)
    try await agent.start()
    let client = ACPClient(transport: a, delegate: delegate)
    try await client.start()
    _ = try await client.initialize()
    let setup = try await client.newSession(cwd: cwd)
    let stopBox = StopBox()
    let events = try await collect(client) {
        stopBox.value = try await client.prompt(sessionId: setup.sessionId, content: [.text(text)])
    }
    let stop = stopBox.value
    await client.close()
    var updates: [SessionUpdate] = []
    for case .sessionUpdate(_, let update) in events { updates.append(update) }
    return (stop, updates)
}

/// 展平子 Agent 包装,得到所有工具调用 ID(含内部更新)。
private func toolCallIds(in updates: [SessionUpdate]) -> [String] {
    var ids: [String] = []
    func visit(_ update: SessionUpdate) {
        switch update {
        case .toolCall(let call): ids.append(call.toolCallId)
        case .childUpdate(_, let inner): visit(inner)
        default: break
        }
    }
    updates.forEach(visit)
    return ids
}

@Suite("演示场景目录", .serialized)
struct DemoScenarioTests {
    static let autoIds = DemoScenarios.all.filter { $0.behavior == .auto }.map(\.id)

    @Test("场景名唯一且只含小写字母、数字与连字符")
    func namesAreUnique() {
        let ids = DemoScenarios.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil })
        #expect(!ids.isEmpty)
    }

    @Test("提示词匹配:旧关键字与 #demo- 场景", arguments: [
        ("#sub", "legacy-sub", false), ("#sub2", "legacy-sub2", false), ("#showcase", "legacy-showcase", false),
        ("#mermaid", "legacy-mermaid", false), ("跑一下 #demo-tools-files 看看", "tools-files", true),
    ])
    func matching(prompt: String, expected: String, isDemo: Bool) {
        let matches = DemoScenarios.matching(prompt: prompt)
        #expect(matches.first?.scenario.id == expected)
        #expect(matches.first?.isDemo == isDemo)
    }

    @Test("未知的 #demo- 名称不匹配任何场景")
    func unknownName() {
        #expect(DemoScenarios.matching(prompt: "#demo-does-not-exist").isEmpty)
    }

    @Test("自动场景跑到 end_turn 且产出更新", arguments: autoIds)
    func autoScenarioFinishes(id: String) async throws {
        let (stop, updates) = try await runPrompt("#demo-\(id)")
        #expect(stop == .endTurn)
        #expect(!updates.isEmpty)
    }

    @Test("交互场景在用户批准后跑到 end_turn", arguments: DemoScenarios.all.filter { $0.behavior == .interactive && $0.id != "changes" }.map(\.id))
    func interactiveScenarioFinishes(id: String) async throws {
        let (stop, updates) = try await runPrompt("#demo-\(id)")
        #expect(stop == .endTurn)
        #expect(!updates.isEmpty)
    }

    @Test("同一会话重复运行场景时工具调用 ID 不重复")
    func idsUniquePerRun() async throws {
        let (a, b) = LoopbackTransport.makePair()
        let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1)
        try await agent.start()
        let client = ACPClient(transport: a, delegate: AllowFirstDelegate())
        try await client.start()
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: NSTemporaryDirectory())
        let events = try await collect(client) {
            _ = try await client.prompt(sessionId: setup.sessionId, content: [.text("#demo-tools-files")])
            _ = try await client.prompt(sessionId: setup.sessionId, content: [.text("#demo-tools-files")])
        }
        await client.close()
        var updates: [SessionUpdate] = []
        for case .sessionUpdate(_, let update) in events { updates.append(update) }
        let ids = toolCallIds(in: updates)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    @Test("冻结场景保持运行,取消后返回 cancelled", arguments: DemoScenarios.all.filter { $0.behavior == .frozen }.map(\.id))
    func frozenScenarioCancels(id: String) async throws {
        let (a, b) = LoopbackTransport.makePair()
        let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1)
        try await agent.start()
        let client = ACPClient(transport: a, delegate: AllowFirstDelegate())
        try await client.start()
        _ = try await client.initialize()
        let setup = try await client.newSession(cwd: NSTemporaryDirectory())
        let task = Task { try await client.prompt(sessionId: setup.sessionId, content: [.text("#demo-\(id)")]) }
        try await Task.sleep(for: .milliseconds(400))
        await client.cancel(sessionId: setup.sessionId)
        let stop = try await task.value
        #expect(stop == .cancelled)
        await client.close()
    }
}
