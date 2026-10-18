// @author ixxxxoooo
// 演示历史会话测试:目录规模与唯一性、session/list 与 session/load 回放(无停顿、终态)。

import Foundation
import Testing
@testable import ACPKit

/// 建立开启演示历史的 Agent 与客户端。
private func makeClient() async throws -> ACPClient {
    let (a, b) = LoopbackTransport.makePair()
    let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1, demoHistory: true)
    try await agent.start()
    let client = ACPClient(transport: a, delegate: AllowFirstDelegate())
    try await client.start()
    _ = try await client.initialize()
    return client
}

@Suite("演示历史会话", .serialized)
struct DemoHistoryTests {
    @Test("每个演示项目 8~12 条会话,ID 全局唯一,含置顶与归档")
    func catalogShape() {
        let projects = ["atlas-web", "notes-cli", "merge-lab", "legacy-api", "empty-project"]
        for name in projects {
            let list = DemoHistory.sessions(forProject: name)
            #expect((8...12).contains(list.count), "\(name) 会话数 \(list.count)")
            #expect(list.contains { $0.pinned })
            #expect(list.contains { $0.archived })
        }
        let ids = DemoHistory.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(DemoHistory.all.map(\.project)) == Set(projects))
    }

    @Test("引用的场景都存在")
    func scenariosExist() {
        for item in DemoHistory.all {
            if case .scenario(let id) = item.body { #expect(DemoScenarios.scenario(named: id) != nil, "\(item.id) 引用了不存在的场景 \(id)") }
        }
    }

    @Test("场景自带开场用户消息时,回放不会再重复插入首条提问")
    func replayDoesNotDuplicateOpeningUser() throws {
        let ctx = ScenarioContext(cwd: "/tmp/x", sessionId: "s")
        let session = try #require(DemoHistory.all.first { if case .scenario("showcase-tour") = $0.body { return true } else { return false } })
        let steps = DemoHistory.replaySteps(for: session, ctx: ctx)
        guard case .user = steps[0] else { Issue.record("回放应以用户消息开头"); return }
        if case .user = steps[1] { Issue.record("首条用户消息被重复插入") }
    }

    @Test("规整后没有停顿、冻结、内置交互与并行")
    func normalizeRemovesLiveOnlySteps() {
        let ctx = ScenarioContext(cwd: "/tmp/x", sessionId: "s")
        for scenario in DemoScenarios.all {
            func check(_ steps: [ScenarioStep]) {
                for step in steps {
                    switch step {
                    case .delay, .hold, .builtin, .permission, .parallel, .stop, .fail, .rateLimit, .elicit, .elicitURL: Issue.record("\(scenario.id) 仍含实时步骤")
                    case .tool(let tool): #expect(tool.finish == .completed || tool.finish == .failed)
                    case .subagent(let sub):
                        #expect(sub.finish == .completed || sub.finish == .failed)
                        check(sub.children)
                    default: break
                    }
                }
            }
            check(DemoHistory.normalize(scenario.build(ctx)))
        }
    }

    @Test("session/list 按项目返回预置目录")
    func listByProject() async throws {
        let client = try await makeClient()
        let result = try await client.listSessions(cwd: "/somewhere/atlas-web")
        #expect(result.sessions.count == DemoHistory.sessions(forProject: "atlas-web").count)
        #expect(result.sessions.contains { $0.title == "梳理 AtlasCore 路由架构" })
        #expect(result.sessions.allSatisfy { $0.updatedAt != nil })
        await client.close()
    }

    @Test("session/load 回放完整内容:用户消息、工具卡、子 Agent 终态", arguments: ["demo-atlas-web-1", "demo-atlas-web-4", "demo-notes-cli-7"])
    func loadReplays(id: String) async throws {
        let client = try await makeClient()
        let started = ContinuousClock.now
        let events = try await collect(client) {
            _ = try await client.loadSession(sessionId: id, cwd: "/somewhere/demo")
        }
        #expect(started.duration(to: .now) < .seconds(2), "回放不应有人为停顿")
        var updates: [SessionUpdate] = []
        for case .sessionUpdate(_, let update) in events { updates.append(update) }
        let first = updates.first
        if case .userMessageChunk(_, let content)? = first, case .text(let text) = content {
            #expect(text == DemoHistory.session(id: id)?.prompt)
        } else {
            Issue.record("回放应以用户消息开头")
        }
        let calls = updates.compactMap { update -> ToolCall? in if case .toolCall(let call) = update { return call } else { return nil } }
        if id != "demo-notes-cli-7" { #expect(!calls.isEmpty) }
        await client.close()
    }

    @Test("斜杠命令 /demo-<名> 与 #demo-<名> 等价")
    func slashCommandMatches() {
        #expect(DemoScenarios.matching(prompt: "/demo-tools-files").first?.scenario.id == "tools-files")
        #expect(DemoScenarios.matching(prompt: "/demo-tools-files").first?.isDemo == true)
        #expect(DemoScenarios.matching(prompt: "/demo-nope").isEmpty)
        #expect(DemoScenarios.commandDescriptors.count == DemoScenarios.all.count)
    }

    @Test("演示模式下新会话下发全部 /demo-* 命令,普通模式不下发")
    func commandsAdvertised() async throws {
        for (demo, expected) in [(true, true), (false, false)] {
            let (a, b) = LoopbackTransport.makePair()
            let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1, demoHistory: demo)
            try await agent.start()
            let client = ACPClient(transport: a, delegate: AllowFirstDelegate())
            try await client.start()
            _ = try await client.initialize()
            let events = try await collect(client, until: { event in
                if case .sessionUpdate(_, .availableCommands) = event { return true } else { return false }
            }) { _ = try await client.newSession(cwd: "/tmp/atlas-web") }
            var names: [String] = []
            for case .sessionUpdate(_, .availableCommands(let commands)) in events { names += commands.map(\.name) }
            #expect(names.contains { $0.hasPrefix("demo-") } == expected)
            if expected { #expect(Set(names).isSuperset(of: Set(DemoScenarios.all.map(\.commandName)))) }
            await client.close()
        }
    }
}
