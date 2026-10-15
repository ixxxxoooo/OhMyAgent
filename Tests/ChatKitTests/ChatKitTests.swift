// @author ygw
// ChatKit 测试:时间线归并、Markdown 解析、事件合并、与 FakeAgent 的端到端会话。

import ACPKit
import AgentHost
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("时间线归并")
struct TimelineStoreTests {
    @Test("同一消息的分片归并为一条,思维结束后开始助手文本")
    func mergesChunks() {
        let store = TimelineStore()
        store.appendUser("你好")
        store.apply(.agentThoughtChunk(messageId: "m1", content: .text("想")))
        store.apply(.agentThoughtChunk(messageId: "m1", content: .text("一下")))
        store.apply(.agentMessageChunk(messageId: "m2", content: .text("答")))
        store.apply(.agentMessageChunk(messageId: "m2", content: .text("复")))
        #expect(store.entries.map(\.kind) == [.user, .thought, .assistant])
        #expect(store.entries[1].text == "想一下")
        #expect(store.entries[1].isStreaming == false)
        #expect(store.entries[2].text == "答复")
        #expect(store.entries[2].isStreaming == true)
        store.finishStreaming()
        #expect(store.entries[2].isStreaming == false)
    }

    @Test("工具调用增量更新同一条目")
    func toolUpdates() {
        let store = TimelineStore()
        store.apply(.toolCall(ToolCall(toolCallId: "t1", title: "读取", kind: .read, status: .pending)))
        store.apply(.toolCallUpdate(toolCallId: "t1", raw: ["status": "completed", "title": "已读取"]))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].tool?.status == .completed)
        #expect(store.entries[0].tool?.title == "已读取")
        #expect(store.entries[0].tool?.kind == .read)
    }

    @Test("未见过的工具更新会创建条目;计划原地更新")
    func unknownToolAndPlan() {
        let store = TimelineStore()
        store.apply(.toolCallUpdate(toolCallId: "x", raw: ["toolCallId": "x", "title": "孤立更新", "status": "in_progress"]))
        #expect(store.entries.count == 1)
        store.apply(.plan([PlanEntry(content: "a", priority: "high", status: "pending")]))
        store.apply(.plan([PlanEntry(content: "a", priority: "high", status: "completed")]))
        #expect(store.entries.filter { $0.kind == .plan }.count == 1)
        #expect(store.entries.last?.plan.first?.status == "completed")
    }

    @Test("工具调用打断文本流后,后续文本为新条目")
    func toolSplitsText() {
        let store = TimelineStore()
        store.apply(.agentMessageChunk(messageId: nil, content: .text("前")))
        store.apply(.toolCall(ToolCall(toolCallId: "t", title: "跑", kind: .execute)))
        store.apply(.agentMessageChunk(messageId: nil, content: .text("后")))
        #expect(store.entries.map(\.kind) == [.assistant, .tool, .assistant])
    }
}

@Suite("Markdown 块解析")
struct MarkdownParserTests {
    @Test("标题、段落、列表、引用、分隔线")
    func basicBlocks() {
        let blocks = MarkdownParser.parse("# 标题\n\n正文第一行\n正文第二行\n\n- 甲\n- 乙\n  - 乙一\n\n> 引用\n\n---")
        #expect(blocks.count == 5)
        #expect(blocks[0] == .heading(level: 1, text: "标题"))
        #expect(blocks[1] == .paragraph("正文第一行\n正文第二行"))
        guard case .list(let items) = blocks[2] else { Issue.record("应为列表"); return }
        #expect(items.count == 3)
        #expect(items[2].level == 1)
        #expect(blocks[3] == .quote("引用"))
        #expect(blocks[4] == .rule)
    }

    @Test("代码围栏与流式中未闭合的围栏")
    func fences() {
        let closed = MarkdownParser.parse("前\n```swift\nlet a = 1\n```\n后")
        #expect(closed == [.paragraph("前"), .code(language: "swift", code: "let a = 1", isClosed: true), .paragraph("后")])
        let open = MarkdownParser.parse("```py\nprint(1)\nprint(2)")
        #expect(open == [.code(language: "py", code: "print(1)\nprint(2)", isClosed: false)])
    }

    @Test("有序列表、任务列表与表格")
    func listsAndTables() {
        let blocks = MarkdownParser.parse("1. 一\n2. 二\n\n- [x] 完成\n- [ ] 待办\n\n| 名称 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |")
        guard case .list(let ordered) = blocks[0], case .list(let tasks) = blocks[1], case .table(let header, let rows) = blocks[2] else {
            Issue.record("块类型不符: \(blocks)"); return
        }
        #expect(ordered.map(\.marker) == ["1.", "2."])
        #expect(tasks.map(\.checked) == [true, false])
        #expect(header == ["名称", "值"])
        #expect(rows == [["a", "1"], ["b", "2"]])
    }
}

@Suite("事件合并")
struct CoalescerTests {
    @Test("窗口内的事件合并为一个批次且保持顺序")
    func batches() async {
        let coalescer = EventCoalescer(interval: .milliseconds(20))
        for index in 0..<50 { coalescer.push(.stderr("\(index)")) }
        var first: [ClientEvent] = []
        for await batch in coalescer.batches {
            first = batch
            break
        }
        #expect(first.count == 50)
        let texts = first.compactMap { event -> String? in
            if case .stderr(let text) = event { return text }
            return nil
        }
        #expect(texts == (0..<50).map(String.init))
    }
}

@MainActor
@Suite("会话端到端(FakeAgent 子进程)")
struct SessionModelTests {
    /// 查找 FakeAgent 可执行文件。
    static func fakeAgentPath() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let candidates = ["\(root)/.build/out/Products/Debug", "\(root)/.build/debug", "\(root)/.build/arm64-apple-macosx/debug"]
        let dir = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/FakeAgent") })
        return "\(dir)/FakeAgent"
    }

    /// 等待条件成立。
    static func wait(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("连接后发送消息得到流式回复,工具调用经权限批准完成")
    func fullTurn() async throws {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try Self.fakeAgentPath())
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.connect()
        #expect(await Self.wait { model.phase == .ready })
        #expect(model.sessionId != nil)

        model.send("你好")
        #expect(await Self.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        #expect(model.timeline.entries.first?.kind == .user)
        #expect(model.timeline.entries.allSatisfy { !$0.isStreaming })

        model.send("请调用工具 tool")
        #expect(await Self.wait { !model.pendingPermissions.isEmpty })
        let prompt = try #require(model.pendingPermissions.first)
        let allow = try #require(prompt.request.options.first { $0.kind == .allowOnce })
        model.resolve(prompt, optionId: allow.optionId)
        #expect(await Self.wait { !model.isRunning })
        let tool = try #require(model.timeline.entries.first { $0.kind == .tool })
        #expect(tool.tool?.status == .completed)
        model.shutdown()
    }

    @Test("连接前发送的消息会排队并在就绪后自动发出")
    func queuedPrompt() async throws {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try Self.fakeAgentPath())
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.send("先发送")
        #expect(model.queuedPrompt == "先发送")
        #expect(await Self.wait { model.timeline.entries.contains { $0.kind == .assistant } && !model.isRunning })
        model.shutdown()
    }

    @Test("缺少可执行文件时进入失败状态并给出原因")
    func failure() async {
        let descriptor = AgentDescriptor(id: "bad", name: "Bad", kind: .genericACP, command: "/nonexistent/agent")
        let model = SessionModel(workspace: URL(fileURLWithPath: NSTemporaryDirectory()), descriptor: descriptor)
        model.connect()
        #expect(await Self.wait { if case .failed = model.phase { return true } else { return false } })
        model.shutdown()
    }
}

@MainActor
@Suite("M3 场景:改动汇总、提问、终端、子 Agent")
struct M3ScenarioTests {
    /// 创建连接好的会话。
    static func readyModel(workspace: URL, terminal: Bool = false) async throws -> SessionModel {
        let descriptor = AgentDescriptor(id: "fake", name: "Fake", kind: .genericACP, command: try SessionModelTests.fakeAgentPath())
        let model = SessionModel(workspace: workspace, descriptor: descriptor)
        model.features.terminal = terminal
        model.connect()
        #expect(await SessionModelTests.wait { model.phase == .ready })
        return model
    }

    static func tempWorkspace() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("编辑经批准后生成本轮改动,可整文件撤销并恢复原内容")
    func editAndRevert() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let file = ws.appendingPathComponent("oma-demo.txt")
        let original = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let model = try await Self.readyModel(workspace: ws)
        model.send("#edit")
        #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
        let prompt = try #require(model.pendingPermissions.first)
        // 权限请求携带 Diff 预览
        #expect(prompt.tool.content.contains { if case .diff = $0 { return true } else { return false } })
        model.resolve(prompt, optionId: "allow")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .changes } })

        let summary = try #require(model.timeline.entries.first { $0.kind == .changes })
        let change = try #require(summary.changes.first)
        #expect(change.path.hasSuffix("oma-demo.txt"))
        #expect(change.diff.added >= 1 && change.diff.removed >= 1)
        #expect(try String(contentsOf: file, encoding: .utf8) != original)

        model.revert(change)
        #expect(await SessionModelTests.wait { change.status == .reverted })
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        model.shutdown()
    }

    @Test("撤销前文件被用户改动则报告冲突且保持原样")
    func revertConflict() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await Self.readyModel(workspace: ws)
        model.send("#edit")
        #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
        model.resolve(try #require(model.pendingPermissions.first), optionId: "allow")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .changes } })
        let change = try #require(model.timeline.entries.first { $0.kind == .changes }?.changes.first)
        #expect(change.original == nil)   // 文件原本不存在
        let file = ws.appendingPathComponent("oma-demo.txt")
        try "用户手工改过\n".write(to: file, atomically: true, encoding: .utf8)
        model.revert(change)
        #expect(await SessionModelTests.wait { change.status == .conflict })
        #expect(try String(contentsOf: file, encoding: .utf8) == "用户手工改过\n")
        model.shutdown()
    }

    @Test("拒绝权限后没有改动汇总")
    func rejectedEdit() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await Self.readyModel(workspace: ws)
        model.send("#edit")
        #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
        model.resolve(try #require(model.pendingPermissions.first), optionId: "reject")
        #expect(await SessionModelTests.wait { !model.isRunning })
        #expect(!model.timeline.entries.contains { $0.kind == .changes })
        #expect(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("oma-demo.txt").path))
        model.shutdown()
    }

    @Test("提问表单:解析字段、校验并回传答案")
    func elicitation() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await Self.readyModel(workspace: ws)
        model.send("#ask")
        #expect(await SessionModelTests.wait { !model.pendingElicitations.isEmpty })
        let prompt = try #require(model.pendingElicitations.first)
        #expect(prompt.message == "请选择实现方案")
        // 字段顺序:question_0, question_0_custom, question_1
        #expect(prompt.fields.map(\.id) == ["question_0", "question_0_custom", "question_1"])
        guard case .single(let options) = prompt.fields[0].kind else { Issue.record("应为单选"); return }
        #expect(options.map(\.value) == ["A", "B"])
        prompt.fields[0].selection = ["B"]
        prompt.fields[2].selection = ["文档", "测试"]
        prompt.accept()
        model.dismiss(prompt)
        #expect(await SessionModelTests.wait { !model.isRunning })
        let reply = model.timeline.entries.first { $0.kind == .assistant }?.text ?? ""
        #expect(reply.contains("\"question_0\":\"B\""))
        // 多选按选项原始顺序输出
        #expect(reply.contains("[\"测试\",\"文档\"]"))
        model.shutdown()
    }

    @Test("声明 terminal 能力后命令输出进入终端会话")
    func terminal() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await Self.readyModel(workspace: ws, terminal: true)
        model.send("#term")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .tool } })
        let session = try #require(model.terminals.values.first)
        #expect(await SessionModelTests.wait { !session.isRunning })
        #expect(session.output.contains("hello-from-terminal"))
        #expect(session.exitCode == 0)
        model.shutdown()
    }

    @Test("子 Agent 的内部更新嵌套在父工具卡片内")
    func subagent() async throws {
        let ws = try Self.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await Self.readyModel(workspace: ws)
        model.send("#sub")
        #expect(await SessionModelTests.wait { !model.isRunning })
        // 顶层只有父工具(及其后的助手文本),子步骤在 childStore 中
        let parent = try #require(model.timeline.entries.first { $0.kind == .tool })
        #expect(parent.tool?.toolCallId == "sub_1")
        let child = try #require(parent.childStore)
        #expect(child.entries.map(\.kind) == [.tool, .assistant])
        #expect(!model.timeline.entries.contains { $0.tool?.toolCallId == "sub_read" })
        model.shutdown()
    }
}

@MainActor
@Suite("M4:补全引擎")
struct CompletionTests {
    @Test("斜杠只在消息开头触发,@ 需位于开头或空白之后")
    func contexts() {
        #expect(CompletionEngine.context(text: "/re", cursor: 3)?.trigger == .slash)
        #expect(CompletionEngine.context(text: "/re", cursor: 3)?.query == "re")
        #expect(CompletionEngine.context(text: "你好 /re", cursor: 6) == nil)
        #expect(CompletionEngine.context(text: "/review 文件", cursor: 11) == nil)
        let mention = CompletionEngine.context(text: "看看 @src/ma", cursor: 10)
        #expect(mention?.trigger == .mention)
        #expect(mention?.query == "src/ma")
        #expect(mention?.range == NSRange(location: 3, length: 7))
        #expect(CompletionEngine.context(text: "a@b", cursor: 3) == nil)
        #expect(CompletionEngine.context(text: "@a b", cursor: 4) == nil)
    }

    @Test("模糊匹配:子序列、前缀与词边界优先")
    func fuzzy() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "abc") == nil)
        let prefix = FuzzyMatcher.score(query: "ma", candidate: "main.swift")!
        let scattered = FuzzyMatcher.score(query: "ma", candidate: "zzzmzzza.swift")!
        #expect(prefix > scattered)
        #expect(FuzzyMatcher.score(query: "tv", candidate: "TimelineView.swift") != nil)
        #expect(FuzzyMatcher.score(query: "", candidate: "任意") == 0)
    }

    @Test("斜杠候选合并本地命令与 Agent 命令并按相关度排序")
    func slashItems() {
        let commands = [AvailableCommand(name: "review", description: "代码审查", inputHint: nil), AvailableCommand(name: "compact", description: "压缩", inputHint: "说明")]
        let all = CompletionEngine.slashItems(query: "", agentCommands: commands)
        #expect(all.count == 4)
        #expect(CompletionEngine.slashItems(query: "rev", agentCommands: commands).first?.insertText == "/review")
        #expect(CompletionEngine.slashItems(query: "zzz", agentCommands: commands).isEmpty)
    }

    @Test("文件索引忽略构建目录,按文件名优先检索")
    func fileIndex() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let fm = FileManager.default
        for dir in ["Sources/App", "node_modules/x", ".git"] { try fm.createDirectory(at: ws.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for file in ["Sources/App/main.swift", "Sources/App/Timeline.swift", "node_modules/x/main.js", ".git/config", "README.md"] {
            try "x".write(to: ws.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let index = FileIndex()
        await index.prepare(root: ws)
        await index.waitUntilReady()
        let all = await index.search("")
        #expect(Set(all) == ["README.md", "Sources/App/main.swift", "Sources/App/Timeline.swift"])
        #expect(await index.search("main").first == "Sources/App/main.swift")
        #expect(await index.search("tl").first == "Sources/App/Timeline.swift")
    }

    @Test("解析消息里真实存在的 @ 文件,忽略不存在与目录,去掉尾部标点")
    func mentions() throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try "x".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let files = CompletionEngine.mentionedFiles(in: "看 @a.txt, 还有 @none.txt @dir @a.txt", workspace: ws)
        #expect(files.map(\.lastPathComponent) == ["a.txt"])
    }
}

@MainActor
@Suite("M4:历史会话与鉴权")
struct HistoryTests {
    @Test("历史列表、打开(回放)、分叉、删除")
    func historyFlow() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        #expect(model.capabilities.loadSession)
        let first = try #require(model.sessionId)
        #expect(await SessionModelTests.wait { model.history.contains { $0.sessionId == first } })

        model.send("第一条")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })

        // 分叉:切到新会话并出现在历史中
        model.forkCurrentSession()
        #expect(await SessionModelTests.wait { model.sessionId != first && model.sessionId != nil })
        let forked = try #require(model.sessionId)
        #expect(await SessionModelTests.wait { model.history.contains { $0.sessionId == forked } })

        // 打开第一个会话:时间线被回放内容替换
        let summary = try #require(model.history.first { $0.sessionId == first })
        model.openSession(summary)
        #expect(await SessionModelTests.wait { !model.isReplaying && model.sessionId == first })
        #expect(model.timeline.entries.first?.kind == .user)
        #expect(model.timeline.entries.contains { $0.kind == .assistant && $0.text.contains("历史回答") })
        #expect(model.timeline.entries.allSatisfy { !$0.isStreaming })

        // 删除分叉出的会话
        let forkSummary = try #require(model.history.first { $0.sessionId == forked })
        model.deleteSession(forkSummary)
        #expect(await SessionModelTests.wait { !model.history.contains { $0.sessionId == forked } })
        model.shutdown()
    }

    @Test("@ 提及作为 resource_link 发送,本地命令 /new 不发给 Agent")
    func mentionAndLocalCommand() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try "x".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        model.send("看看 @a.txt")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })
        let before = try #require(model.sessionId)
        model.send("/new")
        #expect(await SessionModelTests.wait { model.sessionId != before && model.sessionId != nil })
        #expect(model.timeline.entries.isEmpty)
        model.shutdown()
    }

    @Test("补全候选:斜杠含 Agent 命令,@ 返回工作区文件")
    func completionItems() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try "x".write(to: ws.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        let slash = await model.completionItems(for: CompletionContext(trigger: .slash, range: NSRange(location: 0, length: 1), query: ""))
        #expect(slash.contains { $0.insertText == "/new" })
        await model.fileIndex.prepare(root: ws)
        await model.fileIndex.waitUntilReady()
        let files = await model.completionItems(for: CompletionContext(trigger: .mention, range: NSRange(location: 0, length: 1), query: "hel"))
        #expect(files.first?.insertText == "@hello.txt ")
        model.shutdown()
    }

    @Test("鉴权方式来自 initialize,可发起登录")
    func auth() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        let method = try #require(model.authMethods.first)
        model.authenticate(method)
        #expect(await SessionModelTests.wait { model.timeline.entries.contains { $0.text.contains("已通过") } })
        model.shutdown()
    }
}

@Suite("客户端偏好")
struct ClientPrefsTests {
    private func defaults() -> UserDefaults {
        let suite = "oma-test-\(UUID().uuidString)"
        let value = UserDefaults(suiteName: suite)!
        value.removePersistentDomain(forName: suite)
        return value
    }

    @Test("终端输出上限默认 1MB 并被限制在 64KB–16MB")
    func terminalLimit() {
        let store = defaults()
        #expect(ClientPrefs.terminalOutputLimit(store) == 1024 * 1024)
        store.set(1, forKey: ClientPrefs.Key.terminalOutputKB)
        #expect(ClientPrefs.terminalOutputLimit(store) == 64 * 1024)
        store.set(1_000_000, forKey: ClientPrefs.Key.terminalOutputKB)
        #expect(ClientPrefs.terminalOutputLimit(store) == 16_384 * 1024)
    }

    @Test("终端环境过滤只保留最小集合")
    func environmentFilter() {
        let env = ["PATH": "/bin", "SECRET_TOKEN": "x", "HOME": "/h"]
        #expect(ClientPrefs.filterTerminalEnvironment(env, inherit: true) == env)
        #expect(ClientPrefs.filterTerminalEnvironment(env, inherit: false) == ["PATH": "/bin", "HOME": "/h"])
    }

    @Test("路径覆盖忽略空白,预算不为负")
    func overridesAndBudget() {
        let store = defaults()
        store.set("  ", forKey: ClientPrefs.Key.pathNode)
        store.set("/opt/claude", forKey: ClientPrefs.Key.pathClaude)
        #expect(ClientPrefs.pathOverrides(store) == ["claude": "/opt/claude"])
        store.set(-3.0, forKey: ClientPrefs.Key.budgetUSD)
        #expect(ClientPrefs.budgetUSD(store) == 0)
        store.set(5.5, forKey: ClientPrefs.Key.budgetUSD)
        #expect(ClientPrefs.budgetUSD(store) == 5.5)
    }

    @Test("恢复默认只清除客户端前缀的键")
    func reset() {
        let store = defaults()
        store.set(true, forKey: ClientPrefs.Key.editorWrap)
        store.set("keep", forKey: "other.key")
        ClientPrefs.resetAll(store)
        #expect(store.object(forKey: ClientPrefs.Key.editorWrap) == nil)
        #expect(store.string(forKey: "other.key") == "keep")
    }
}

@Suite("客户端能力")
struct ClientFeaturesTests {
    @Test("默认只开启提问表单,可被偏好覆盖")
    func defaultsAndOverride() {
        let suite = "oma-feat-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let base = ClientFeatures.load(store)
        #expect(!base.fileSystem && !base.terminal && base.elicitation)
        store.set(true, forKey: "feature.terminal")
        store.set(false, forKey: "feature.elicitation")
        let changed = ClientFeatures.load(store)
        #expect(changed.terminal && !changed.elicitation)
    }
}

@MainActor
@Suite("Agent 注册表模型与会话接入")
struct AgentIntegrationTests {
    private func tempStore() -> AgentRegistryStore {
        AgentRegistryStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-reg-\(UUID().uuidString)/agents.json"))
    }

    @Test("新增/校验/默认/停用/删除都会写回文件")
    func registryMutations() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = AgentRegistryModel(store: store)
        #expect(model.upsert(AgentDescriptor(id: "", name: "x", kind: .genericACP, command: "x")) != nil)
        #expect(model.upsert(AgentDescriptor(id: "claude-code", name: "冒名", kind: .genericACP, command: "x")) != nil)
        #expect(model.upsert(AgentDescriptor(id: "g", name: "G", kind: .genericACP, command: " ")) != nil)
        #expect(model.upsert(AgentDescriptor(id: "goose", name: "Goose", kind: .genericACP, command: "goose", args: ["acp"])) == nil)
        model.setDefault(agentId: "goose")
        #expect(AgentRegistryModel(store: store).data.resolvedDefault.id == "goose")
        model.setEnabled(false, agentId: "goose")
        #expect(model.data.defaultAgent == nil)
        #expect(AgentRegistryModel(store: store).data.enabledAgents.map(\.id) == ["claude-code", "claude-direct"])
        model.remove(agentId: "goose")
        #expect(AgentRegistryModel(store: store).data.agents.isEmpty)
    }

    @Test("仅在缺 Node / 适配器且开启兜底时回退直连")
    func fallbackRules() {
        let model = SessionModel(workspace: URL(fileURLWithPath: "/tmp"), descriptor: .claudeCode)
        var registry = AgentRegistryData()
        #expect(model.shouldFallBackToDirect(error: AgentLaunchError.missingNode, descriptor: .claudeCode, registry: registry))
        #expect(model.shouldFallBackToDirect(error: AgentLaunchError.missingAdapter, descriptor: .claudeCode, registry: registry))
        #expect(!model.shouldFallBackToDirect(error: AgentLaunchError.missingClaude, descriptor: .claudeCode, registry: registry))
        #expect(!model.shouldFallBackToDirect(error: AgentLaunchError.missingNode, descriptor: .claudeDirect, registry: registry))
        #expect(!model.shouldFallBackToDirect(error: AgentLaunchError.missingNode, descriptor: AgentDescriptor(id: "g", name: "G", kind: .genericACP, command: "g"), registry: registry))
        registry.directFallback = false
        #expect(!model.shouldFallBackToDirect(error: AgentLaunchError.missingNode, descriptor: .claudeCode, registry: registry))
    }

    @Test("MCP 注入包含已启用的 Agent-as-MCP,Bridge 关闭时不启动")
    func prepareServers() {
        let model = SessionModel(workspace: URL(fileURLWithPath: "/tmp"), descriptor: .claudeCode)
        var registry = AgentRegistryData()
        registry.mcpAgents = [AgentMCPEntry(id: "codex", name: "Codex", command: "codex", args: ["mcp-server"], enabled: true),
                              AgentMCPEntry(id: "off", name: "Off", command: "off", enabled: false)]
        registry.bridge.enabled = false
        let prepared = model.prepareMCPServers(registry: registry, environment: ["PATH": ""])
        #expect(prepared.bridge == nil)
        #expect(prepared.servers.count == 1)
        #expect(prepared.servers.first == .stdio(name: "agent_codex", command: "codex", args: ["mcp-server"], env: [:]))
    }

    @Test("Bridge 的打开文件与选区工具作用于会话模型")
    func bridgeTools() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let model = SessionModel(workspace: dir, descriptor: .claudeCode)
        let opened = model.bridgeOpenFile(path: "a.txt", line: 2)
        #expect(!opened.isError)
        #expect(model.viewerRequest?.path == dir.appendingPathComponent("a.txt").path)
        #expect(model.viewerRequest?.line == 2)
        #expect(model.bridgeOpenFile(path: "missing.txt", line: nil).isError)
        #expect(model.bridgeSelection().text.contains("没有选中"))
        model.selectedText = "选中内容"
        #expect(model.bridgeSelection().text == "选中内容")
        #expect(model.bridgeNotify(title: "t", message: "m").isError)
        var received: (String, String)?
        model.notifier = { received = ($0, $1) }
        #expect(!model.bridgeNotify(title: "t", message: "m").isError)
        #expect(received?.0 == "t")
    }
}

@Suite("渲染性能基线")
struct RenderPerformanceTests {
    @Test("Markdown 解析 300KB 文本 < 1s(debug 构建)")
    func markdownParseBudget() {
        let section = "## 标题\n\n这是一段包含 **加粗**、`行内代码` 与 [链接](https://example.com) 的正文,用来模拟长回答。\n\n- 列表项一\n- 列表项二\n\n```swift\nlet value = 42\nprint(value)\n```\n\n"
        let text = String(repeating: section, count: 1500)
        let clock = ContinuousClock()
        var blocks = 0
        let elapsed = clock.measure { blocks = MarkdownParser.parse(text).count }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("【基线】Markdown \(text.utf8.count / 1024)KB 解析 \(String(format: "%.3f", seconds))s,\(blocks) 块")
        #expect(seconds < 1)
        #expect(blocks > 1000)
    }
}

@Suite("更新检查")
struct UpdateCheckerTests {
    private func feed(_ version: String, build: Int? = nil, minimum: String? = nil, url: String = "https://example.com/a.dmg") -> Data {
        var info: [String: Any] = ["version": version, "url": url]
        if let build { info["build"] = build }
        if let minimum { info["minimumSystemVersion"] = minimum }
        return try! JSONSerialization.data(withJSONObject: ["stable": info, "preview": ["version": "9.0.0", "url": "https://example.com/p.dmg"]])
    }

    @Test("点分版本比较")
    func compareVersions() {
        #expect(UpdateChecker.compare("0.10.0", "0.9.9") == 1)
        #expect(UpdateChecker.compare("1.0", "1.0.0") == 0)
        #expect(UpdateChecker.compare("1.2.3-beta", "1.2.4") == -1)
    }

    @Test("发现新版本 / 已是最新 / 同版本更高构建号")
    func evaluateResults() {
        #expect(UpdateChecker.evaluate(data: feed("0.2.0"), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .available(UpdateInfo(version: "0.2.0", url: "https://example.com/a.dmg")))
        #expect(UpdateChecker.evaluate(data: feed("0.1.0"), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .upToDate)
        #expect(UpdateChecker.evaluate(data: feed("0.1.0", build: 5), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) != .upToDate)
        if case .available(let info) = UpdateChecker.evaluate(data: feed("0.2.0"), channel: "preview", currentVersion: "0.1.0", currentBuild: 1) { #expect(info.version == "9.0.0") } else { Issue.record("预览通道应返回 9.0.0") }
    }

    @Test("系统版本不满足、坏数据与坏地址")
    func failures() {
        #expect(UpdateChecker.evaluate(data: feed("0.2.0", minimum: "99.0"), channel: "stable", currentVersion: "0.1.0", currentBuild: 1, systemVersion: "27.0") == .unsupportedSystem(UpdateInfo(version: "0.2.0", url: "https://example.com/a.dmg", minimumSystemVersion: "99.0")))
        #expect(UpdateChecker.evaluate(data: Data("{}".utf8), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .failed("发布源缺少 stable 通道"))
        #expect(UpdateChecker.evaluate(data: Data("nope".utf8), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .failed("发布源格式不正确"))
        #expect(UpdateChecker.evaluate(data: feed("0.2.0", url: "javascript:alert(1)"), channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .failed("发布源中的下载地址无效"))
    }

    @Test("拉取:拒绝非 https、支持注入数据、网络错误转为失败")
    func fetching() async {
        let data = feed("0.2.0")
        #expect(await UpdateChecker.check(feedURL: "", channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .failed("尚未配置更新源地址"))
        #expect(await UpdateChecker.check(feedURL: "http://evil.example.com/feed.json", channel: "stable", currentVersion: "0.1.0", currentBuild: 1) == .failed("更新源必须使用 https"))
        let ok = await UpdateChecker.check(feedURL: "https://example.com/feed.json", channel: "stable", currentVersion: "0.1.0", currentBuild: 1, fetch: { _ in data })
        if case .available = ok {} else { Issue.record("应发现更新") }
        struct Boom: Error {}
        let bad = await UpdateChecker.check(feedURL: "https://example.com/feed.json", channel: "stable", currentVersion: "0.1.0", currentBuild: 1, fetch: { _ in throw Boom() })
        if case .failed = bad {} else { Issue.record("应失败") }
    }

    @Test("自动检查 24 小时节流")
    func throttle() {
        let now = Date()
        #expect(UpdateChecker.shouldAutoCheck(last: nil, now: now))
        #expect(!UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-25 * 3600), now: now))
    }
}
