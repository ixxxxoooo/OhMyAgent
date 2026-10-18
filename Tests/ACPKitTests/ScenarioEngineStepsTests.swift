// @author ixxxxoooo
// 场景引擎新增步骤测试:回合终止原因、JSON-RPC 失败、限额更新、用户消息图片、历史回放规整。

import Foundation
import Testing
@testable import ACPKit

/// 在内存传输上直接执行一组步骤并收集全部会话更新。
private func execute(_ steps: [ScenarioStep]) async throws -> (outcome: ScenarioOutcome?, error: Error?, updates: [SessionUpdate]) {
    let (a, b) = LoopbackTransport.makePair()
    let agent = ScriptedAgent(transport: b, chunkDelayMillis: 1, demoHistory: true)
    try await agent.start()
    let client = ACPClient(transport: a, delegate: AllowFirstDelegate())
    try await client.start()
    _ = try await client.initialize()
    let setup = try await client.newSession(cwd: NSTemporaryDirectory())
    let ctx = ScenarioContext(cwd: NSTemporaryDirectory(), sessionId: setup.sessionId)
    final class Box: @unchecked Sendable { var outcome: ScenarioOutcome?; var error: Error? }
    let box = Box()
    let events = try await collect(client) {
        do { box.outcome = try await agent.runSteps(steps, ctx: ctx) } catch { box.error = error }
    }
    await client.close()
    var updates: [SessionUpdate] = []
    for case .sessionUpdate(_, let update) in events { updates.append(update) }
    return (box.outcome, box.error, updates)
}

@Suite("场景引擎:回合终止与扩展步骤", .serialized)
struct ScenarioEngineStepsTests {
    @Test("stop 步骤以指定停止原因结束,后续步骤不再执行")
    func stopEndsTurn() async throws {
        let result = try await execute([.text(["前"]), .stop("refusal"), .text(["后"])])
        #expect(result.outcome == .stopped("refusal"))
        let texts = result.updates.compactMap { update -> String? in
            if case .agentMessageChunk(_, let content) = update, case .text(let value) = content { return value }
            return nil
        }
        #expect(texts == ["前"])
    }

    @Test("fail 步骤抛出带错误码的 JSON-RPC 错误")
    func failThrows() async throws {
        let result = try await execute([.fail(code: -32000, message: "Authentication required")])
        let rpc = try #require(result.error as? JSONRPCError)
        #expect(rpc.code == -32000 && rpc.isAuthRequired)
    }

    @Test("rateLimit 步骤沿用最近的上下文用量并带上整组窗口")
    func rateLimitKeepsUsage() async throws {
        let result = try await execute([
            .usage(used: 91_000, size: 200_000, cost: nil),
            .rateLimit([ScenarioRateWindow("five_hour", 0.82, resetsInMinutes: 47), ScenarioRateWindow("seven_day", 0.31, resetsInMinutes: 3000)]),
        ])
        let usages = result.updates.compactMap { update -> UsageUpdate? in
            if case .usage(let value) = update { return value }
            return nil
        }
        #expect(usages.count == 2)
        #expect(usages.last?.used == 91_000 && usages.last?.size == 200_000)
        let windows = usages.last?.rateLimit?["unifiedWindows"]?.objectValue ?? [:]
        #expect(Set(windows.keys) == ["five_hour", "seven_day"])
        #expect(windows["five_hour"]?["utilization"]?.doubleValue == 0.82)
    }

    @Test("userImage 步骤发出图片内容块,PNG 数据有效且按种类缓存")
    func userImageEmitsBlock() async throws {
        let result = try await execute([.user("看下这个页面"), .userImage(.errorPage)])
        let images = result.updates.compactMap { update -> String? in
            if case .userMessageChunk(_, let content) = update, case .image(let data, let mime, _) = content, mime == "image/png" { return data }
            return nil
        }
        #expect(images.count == 1)
        let base64 = try #require(images.first)
        let data = try #require(Data(base64Encoded: base64))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(ScenarioImages.png(.errorPage) == ScenarioImages.png(.errorPage))
        for kind in ScenarioImageKind.allCases { #expect(!ScenarioImages.png(kind).isEmpty) }
    }

    @Test("历史回放规整会去掉终止/报错/限额步骤")
    func normalizeDropsTerminalSteps() {
        let steps: [ScenarioStep] = [.text(["a"]), .rateLimit([]), .fail(code: -32000, message: "x"), .stop("refusal")]
        let normalized = DemoHistory.normalize(steps)
        #expect(normalized.count == 1)
    }
}
