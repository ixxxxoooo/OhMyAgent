// @author ixxxxoooo
// Claude Code 交互补全:客户端命令、斜杠来源标注、@子 Agent 提及、运行中引导/排队、目标、图片、提示行。

import ACPKit
import AgentHost
import Foundation
import Testing
@testable import ChatKit

@Suite("客户端命令解析")
struct LocalCommandTests {
    @Test("目录内的命令都能被解析")
    func catalogParses() {
        #expect(LocalCommands.parse("/new") == .newConversation)
        #expect(LocalCommands.parse("/clear") == .newConversation)
        #expect(LocalCommands.parse("/help") == .help)
        #expect(LocalCommands.parse("/config") == .settings(page: "general"))
        #expect(LocalCommands.parse("/agents") == .extensions(section: "agents"))
        #expect(LocalCommands.parse("/memory") == .extensions(section: "memory"))
        #expect(LocalCommands.parse("/resume") == .history)
        #expect(LocalCommands.parse("/export") == .exportTranscript)
        #expect(LocalCommands.parse("/rename 我的会话") == .rename("我的会话"))
        #expect(LocalCommands.parse("/model sonnet") == .setModel("sonnet"))
        #expect(LocalCommands.parse("/model") == .modelMenu)
    }

    @Test("带参数的 /mcp 与未知命令交给 Agent")
    func agentOwned() {
        #expect(LocalCommands.parse("/mcp") == .mcpPanel)
        #expect(LocalCommands.parse("/mcp reconnect github") == nil)
        #expect(LocalCommands.parse("/compact") == nil)
        #expect(LocalCommands.parse("/goal 修好测试") == nil)
        #expect(LocalCommands.parse("普通文本") == nil)
        #expect(LocalCommands.parse("/new\n多行") == nil)
        #expect(LocalCommands.parse("/clear 额外参数") == nil)
    }

    @Test("目录中的每个命令名都有解析分支")
    func catalogCovered() {
        for spec in LocalCommands.catalog {
            let input = spec.hint == nil || spec.name == "mcp" || spec.name == "model" ? "/\(spec.name)" : "/\(spec.name) x"
            #expect(LocalCommands.parse(input) != nil, "/\(spec.name) 没有解析分支")
        }
    }

    @Test("帮助文本包含全部命令")
    func help() {
        let text = LocalCommands.helpMarkdown(agentCommandCount: 73)
        for spec in LocalCommands.catalog { #expect(text.contains("/\(spec.name)")) }
        #expect(text.contains("73"))
    }
}

@Suite("补全:来源标注与子 Agent 提及")
struct CompletionParityTests {
    private let commands = [
        AvailableCommand(name: "compact", description: "压缩上下文", inputHint: nil),
        AvailableCommand(name: "deploy", description: "", inputHint: nil),
        AvailableCommand(name: "mcp__github__review", description: "GitHub 审查", inputHint: nil),
        AvailableCommand(name: "tools:lint", description: "", inputHint: nil),
    ]
    private let entries = [
        SlashEntry(name: "deploy", summary: "部署项目", badge: "Skill", kind: .skill),
        SlashEntry(name: "tools:lint", summary: "运行 lint", badge: "项目", kind: .customCommand),
    ]

    @Test("Agent 命令按本机配置标注 Skill/自定义/MCP/内置")
    func badges() {
        let items = CompletionEngine.slashItems(query: "", agentCommands: commands, entries: entries)
        func kind(_ text: String) -> CompletionItem.Kind? { items.first { $0.insertText == text }?.kind }
        #expect(kind("/deploy") == .skill)
        #expect(kind("/tools:lint") == .customCommand)
        #expect(kind("/mcp__github__review") == .mcpPrompt)
        #expect(kind("/compact") == .agentCommand)
        #expect(items.first { $0.insertText == "/deploy" }?.subtitle == "部署项目")
    }

    @Test("客户端命令排在同分的 Agent 命令之前")
    func localFirst() {
        let items = CompletionEngine.slashItems(query: "", agentCommands: commands, entries: entries)
        #expect(items.first?.kind == .localCommand)
    }

    @Test("Agent 尚未通告命令时用本机 Skills 兜底")
    func fallback() {
        let items = CompletionEngine.slashItems(query: "dep", agentCommands: [], entries: entries)
        #expect(items.first?.insertText == "/deploy")
    }

    @Test("@agent- 提及按名称过滤")
    func agentMentions() {
        let agents = [(name: "explorer", summary: "搜索代码", badge: "用户"), (name: "reviewer", summary: "审查", badge: "项目")]
        #expect(CompletionEngine.agentMentionItems(query: "", agents: agents).count == 2)
        let found = CompletionEngine.agentMentionItems(query: "agent-rev", agents: agents)
        #expect(found.first?.insertText == "@agent-reviewer ")
        #expect(CompletionEngine.agentMentionItems(query: "zzz", agents: agents).isEmpty)
    }
}

@MainActor
@Suite("提示行与计划文档")
struct NoticeTimelineTests {
    @Test("notice 更新生成带详情的提示行")
    func notice() {
        let store = TimelineStore()
        store.apply(.notice(severity: "warning", title: "上下文已压缩", detail: "旧消息已被摘要"))
        let entry = store.entries.last
        #expect(entry?.kind == .notice)
        #expect(entry?.severity == "warning")
        #expect(entry?.detail == "旧消息已被摘要")
        #expect(entry?.isError == false)
    }

    @Test("plan_update 的 Markdown 计划成为计划文档")
    func planDoc() {
        let store = TimelineStore()
        store.apply(.planMarkdown("# 计划\n- 第一步"))
        #expect(store.entries.last?.kind == .planDoc)
        #expect(store.entries.last?.text.contains("第一步") == true)
    }

    @Test("用户消息保留图片附件与引导标记")
    func userAttachments() {
        let store = TimelineStore()
        let image = ImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", name: "a.png")
        store.appendUser("看图", attachments: [image], steered: true)
        #expect(store.entries.last?.attachments.count == 1)
        #expect(store.entries.last?.isSteered == true)
    }

    @Test("会话导出为 Markdown")
    func export() {
        let store = TimelineStore()
        store.appendUser("你好")
        store.apply(.agentMessageChunk(messageId: nil, content: .text("世界")))
        store.finishStreaming()
        let text = TranscriptExporter.markdown(entries: store.entries, title: "测试", workspace: "/tmp/x")
        #expect(text.hasPrefix("# 测试"))
        #expect(text.contains("## 你"))
        #expect(text.contains("世界"))
    }
}

@MainActor
@Suite("会话:引导、排队、目标、图片、命令")
struct SessionParityTests {
    private func model() async throws -> SessionModel {
        let ws = try M3ScenarioTests.tempWorkspace()
        return try await M3ScenarioTests.readyModel(workspace: ws)
    }

    @Test("运行中的消息被引导进当前轮次")
    func steering() async throws {
        let model = try await model()
        #expect(model.capabilities.canSteer)
        model.send("slow #long 请持续输出")
        #expect(await SessionModelTests.wait { model.isRunning })
        model.send("改成只回答一句")
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.kind == .user && $0.isSteered } })
        model.cancel()
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("⌘Return 排队的消息在本轮正常结束后自动发送")
    func followUp() async throws {
        let model = try await model()
        model.send("slow 第一条")
        #expect(await SessionModelTests.wait { model.isRunning })
        model.send("第二条", afterTurn: true)
        #expect(model.followUps.count == 1)
        #expect(await SessionModelTests.wait(timeout: .seconds(15)) {
            !model.isRunning && model.followUps.isEmpty && model.timeline.entries.filter { $0.kind == .user }.count == 2
        })
        model.shutdown()
    }

    @Test("排队消息可删除")
    func removeFollowUp() async throws {
        let model = try await model()
        model.enqueueFollowUp("甲")
        model.enqueueFollowUp("乙")
        let id = try #require(model.followUps.first?.id)
        model.removeFollowUp(id)
        #expect(model.followUps.map(\.text) == ["乙"])
        model.shutdown()
    }

    @Test("/goal 设置目标,/goal clear 清除,轮次结束后目标变为已结束")
    func goal() async throws {
        let model = try await model()
        model.send("/goal 让所有测试通过")
        #expect(model.goal?.objective == "让所有测试通过")
        #expect(await SessionModelTests.wait { !model.isRunning })
        #expect(model.goal?.isActive == false)
        model.send("/goal clear")
        #expect(model.goal == nil)
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("带图片的消息写入附件")
    func images() async throws {
        let model = try await model()
        #expect(model.canAttachImages)
        let image = ImageAttachment(data: Data([0x89, 0x50]), mimeType: "image/png", name: "shot.png")
        model.addAttachment(image)
        #expect(model.attachments.count == 1)
        model.sendDraft()
        #expect(model.attachments.isEmpty)
        #expect(model.timeline.entries.first { $0.kind == .user }?.attachments.count == 1)
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("尚未连接时也能添加图片(能力未确定时先允许),不会悄悄丢弃")
    func imagesBeforeConnect() throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try SessionModelTests.fakeAgentPath())
        let model = SessionModel(workspace: ws, descriptor: descriptor)
        #expect(model.phase != .ready)
        #expect(model.canAttachImages)
        model.addAttachment(ImageAttachment(data: Data([0x89, 0x50]), mimeType: "image/png", name: "early.png"))
        #expect(model.attachments.count == 1)
    }

    @Test("超大图片被拒绝并提示")
    func oversizedImage() async throws {
        let model = try await model()
        model.addAttachment(ImageAttachment(data: Data(count: ImageAttachment.maxBytes + 1), mimeType: "image/png", name: "big.png"))
        #expect(model.attachments.isEmpty)
        #expect(model.timeline.entries.last?.kind == .notice)
        model.shutdown()
    }

    @Test("/help 与 /status 生成带详情的提示行,/rename 持久化标题")
    func localCommands() async throws {
        let model = try await model()
        model.send("/help")
        #expect(model.timeline.entries.last?.detail?.contains("/rename") == true)
        model.send("/status")
        #expect(model.timeline.entries.last?.detail?.contains("工作区") == true)
        let id = try #require(model.sessionId)
        model.send("/rename 新标题")
        #expect(model.sessionTitle == "新标题")
        #expect(ClientPrefs.sessionTitleOverrides()[id] == "新标题")
        ClientPrefs.setSessionTitle(nil, for: id)
        model.shutdown()
    }

    @Test("需要界面的命令经 onLocalCommand 交给应用层")
    func uiCommands() async throws {
        let model = try await model()
        var received: [LocalCommand] = []
        model.onLocalCommand = { received.append($0) }
        model.send("/agents")
        model.send("/mcp")
        model.send("/config")
        #expect(received == [.extensions(section: "agents"), .mcpPanel, .settings(page: "general")])
        model.shutdown()
    }

    @Test("notice 经真实更新链路出现在时间线")
    func noticeFlow() async throws {
        let model = try await model()
        model.send("#notice")
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.kind == .notice && $0.severity == "warning" } })
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("排队消息可取回输入框编辑:文字并入草稿并从队列移除")
    func editFollowUp() async throws {
        let model = try await model()
        model.enqueueFollowUp("甲")
        let id = try #require(model.followUps.first?.id)
        model.draft = ""
        model.editFollowUp(id)
        #expect(model.followUps.isEmpty && model.draft == "甲")
        model.enqueueFollowUp("乙")
        model.editFollowUp(try #require(model.followUps.first?.id))
        #expect(model.draft == "甲\n乙")
        model.shutdown()
    }
}

@MainActor
@Suite("排队消息:立即发送")
struct FollowUpNowTests {
    private func model() async throws -> SessionModel {
        let ws = try M3ScenarioTests.tempWorkspace()
        return try await M3ScenarioTests.readyModel(workspace: ws)
    }

    /// 注:偏好为「排队」时同样应注入(已手动验证);全局偏好会污染并行测试,故此处不改它。
    @Test("运行中点「引导」:排队消息立刻注入当前轮次并出队")
    func sendNowSteers() async throws {
        let model = try await model()
        model.send("slow #long 请持续输出")
        #expect(await SessionModelTests.wait { model.isRunning })
        model.send("补充一句", afterTurn: true)
        let id = try #require(model.followUps.first?.id)
        model.sendFollowUpNow(id)
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.kind == .user && $0.isSteered } })
        #expect(model.followUps.isEmpty)
        model.cancel()
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }

    @Test("空闲时点「发送」:排队消息直接发出并出队")
    func sendNowWhenIdle() async throws {
        let model = try await model()
        model.enqueueFollowUp("单独发送")
        let id = try #require(model.followUps.first?.id)
        model.sendFollowUpNow(id)
        #expect(model.followUps.isEmpty)
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.kind == .user && $0.text == "单独发送" } })
        #expect(await SessionModelTests.wait { !model.isRunning })
        model.shutdown()
    }
}
