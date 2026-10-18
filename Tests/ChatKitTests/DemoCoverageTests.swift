// @author ixxxxoooo
// 演示模式覆盖守卫:演示场景必须覆盖全部工具呈现类别、时间线条目类型与工具状态。
// 以后新增卡片类型却没有补演示场景,这里会失败,避免演示模式随版本腐烂。

import ACPKit
import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("演示模式覆盖守卫(FakeAgent 子进程)", .serialized)
struct DemoCoverageTests {
    /// 递归收集时间线内(含子 Agent)的全部工具调用。
    static func allTools(in store: TimelineStore) -> [ToolCall] {
        var result: [ToolCall] = []
        for entry in store.entries {
            if let tool = entry.tool { result.append(tool) }
            if let child = entry.childStore { result.append(contentsOf: allTools(in: child)) }
        }
        return result
    }

    /// 发送一个演示场景并等待本轮结束。
    static func run(_ model: SessionModel, _ scenario: String, timeout: Duration = .seconds(90)) async -> Bool {
        model.send("#demo-\(scenario)")
        _ = await SessionModelTests.wait(timeout: .seconds(5)) { model.isRunning }
        return await SessionModelTests.wait(timeout: timeout) { !model.isRunning }
    }

    @Test("全量串联场景覆盖全部工具呈现类别与自动场景的条目类型")
    func coversCategoriesAndKinds() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        #expect(await Self.run(model, "all"))
        #expect(await Self.run(model, "roles"))

        let tools = Self.allTools(in: model.timeline)
        let categories = Set(tools.map { ToolPresentation(tool: $0, hasChild: false).category })
        for category in ToolPresentation.Category.allCases {
            #expect(categories.contains(category), "演示场景缺少工具类别:\(category.rawValue)")
        }
        // 终态覆盖:完成与失败
        #expect(tools.contains { $0.status == .completed })
        #expect(tools.contains { $0.status == .failed })

        // 时间线条目类型(changes 需要真实改文件,在下一个测试里覆盖)
        var kinds = Set(model.timeline.entries.map(\.kind))
        for entry in model.timeline.entries { if let child = entry.childStore { kinds.formUnion(child.entries.map(\.kind)) } }
        for kind in [TimelineEntry.Kind.user, .assistant, .thought, .tool, .plan, .notice, .planDoc, .turnSummary] {
            #expect(kinds.contains(kind), "演示场景缺少条目类型:\(kind)")
        }
        // 工具结果里的图片内容块(浏览器截图、读取图片)
        let withImage = tools.filter { $0.content.contains { if case .content(.image) = $0 { return true } else { return false } } }
        #expect(withImage.count >= 3, "演示场景缺少带图片结果的工具卡")
        // 子 Agent:嵌套与多种类型
        let types = Set(tools.compactMap { $0.rawInput?["subagent_type"]?.stringValue })
        #expect(types.isSuperset(of: ["Explore", "code-reviewer", "general-purpose"]))
        #expect(model.timeline.subagentEntries().contains { $0.depth >= 1 })
        model.shutdown()
    }

    @Test("冻结场景产生待处理与进行中的工具卡,取消后结束")
    func frozenStates() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("#demo-states-frozen")
        let expected: Set<ToolStatus> = [.pending, .inProgress, .completed]
        #expect(await SessionModelTests.wait { Set(Self.allTools(in: model.timeline).map(\.status)).isSuperset(of: expected) })
        #expect(model.isRunning)
        model.cancel()
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("本轮改动汇总:changes 场景批准后生成改动条目")
    func changesEntry() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("#demo-changes")
        #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
        if let prompt = model.pendingPermissions.first { model.resolve(prompt, optionId: "allow") }
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .changes } })
        model.shutdown()
    }

    @Test("切换模型会在时间线插入「由 X 切换为 Y」分割线,切回同一模型不重复插入")
    func modelSwitchDivider() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.setConfigOption("model", value: "scripted-2")
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.kind == .modelSwitch } })
        let entry = try #require(model.timeline.entries.last { $0.kind == .modelSwitch })
        #expect(entry.text == "Scripted 1" && entry.detail == "Scripted 2")
        // 设置为当前值:不应再追加
        model.setConfigOption("model", value: "scripted-2")
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.timeline.entries.filter { $0.kind == .modelSwitch }.count == 1)
        model.shutdown()
    }

    @Test("交互场景:权限、计划批准、提问向导都会挂起等待用户")
    func interactiveScenarios() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)

        model.send("#demo-permissions")
        for _ in 0..<3 {
            #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
            if let prompt = model.pendingPermissions.first { model.resolve(prompt, optionId: "allow") }
        }
        #expect(await SessionModelTests.wait { !model.isRunning })

        // 权限变体:前三个依次批准,最后两个命令同时请求(堆叠)
        model.send("#demo-permissions-variants")
        for _ in 0..<3 {
            #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
            if let prompt = model.pendingPermissions.first { model.resolve(prompt, optionId: "allow") }
        }
        #expect(await SessionModelTests.wait { model.pendingPermissions.count == 2 })
        for prompt in model.pendingPermissions { model.resolve(prompt, optionId: "allow") }
        #expect(await SessionModelTests.wait { !model.isRunning })

        model.send("#demo-plan-approval")
        #expect(await SessionModelTests.wait { model.pendingPermissions.first?.isPlanApproval == true })
        if let prompt = model.pendingPermissions.first { model.resolve(prompt, optionId: "default") }
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .planDoc } })

        model.send("#demo-ask")
        #expect(await SessionModelTests.wait { !model.pendingElicitations.isEmpty })
        if let prompt = model.pendingElicitations.first { prompt.cancel(); model.dismiss(prompt) }
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }
}
