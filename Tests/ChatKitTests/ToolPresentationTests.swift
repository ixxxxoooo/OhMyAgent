// @author ixxxxoooo
// 工具呈现、搜索结果解析、ANSI 解析与时间线分组测试。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("工具呈现")
struct ToolPresentationTests {
    private func tool(_ name: String, kind: ToolKind, input: JSONValue? = nil, title: String = "", content: [ToolCallContent] = [], locations: [ToolLocation] = []) -> ToolCall {
        ToolCall(toolCallId: UUID().uuidString, name: name, title: title, kind: kind, status: .completed, content: content, locations: locations, rawInput: input)
    }

    @Test("读取:路径与行范围")
    func read() {
        let p = ToolPresentation(tool: tool("Read", kind: .read, input: ["file_path": "/a/b.swift", "offset": 10, "limit": 50]))
        #expect(p.category == .read)
        #expect(p.verb == "读取")
        #expect(p.subject == "/a/b.swift")
        #expect(p.subjectIsPath)
        #expect(p.detail == "L10-59")
        let q = ToolPresentation(tool: tool("Read", kind: .read, input: ["file_path": "/a/b.swift"], locations: [ToolLocation(path: "/a/b.swift", line: 7)]))
        #expect(q.detail == "L7")
        #expect(ToolPresentation(tool: tool("Read", kind: .read, input: ["file_path": "/x", "limit": 20])).detail == "前 20 行")
    }

    @Test("写入与编辑区分:Write 或旧文本为空视为写入")
    func writeVsEdit() {
        let new = tool("Write", kind: .edit, input: ["file_path": "/a.md"], content: [.diff(path: "/a.md", oldText: nil, newText: "x")])
        #expect(ToolPresentation(tool: new).category == .write)
        let edit = tool("Edit", kind: .edit, input: ["file_path": "/a.md"], content: [.diff(path: "/a.md", oldText: "a", newText: "b")])
        let p = ToolPresentation(tool: edit)
        #expect(p.category == .edit)
        #expect(p.verb == "编辑")
        // 无 name 但 Diff 旧文本为空
        let anonymous = tool("", kind: .edit, content: [.diff(path: "/n", oldText: nil, newText: "x")], locations: [ToolLocation(path: "/n")])
        #expect(ToolPresentation(tool: anonymous).category == .write)
    }

    @Test("搜索、终端、联网、MCP、子任务")
    func others() {
        let grep = ToolPresentation(tool: tool("Grep", kind: .search, input: ["pattern": "TODO", "path": "/p/Sources"]))
        #expect(grep.verb == "搜索" && grep.subject == "TODO" && grep.detail == "Sources")
        let glob = ToolPresentation(tool: tool("Glob", kind: .search, input: ["pattern": "**/*.swift"]))
        #expect(glob.verb == "查找文件")
        let bash = ToolPresentation(tool: tool("Bash", kind: .execute, input: ["command": "ls -la\necho hi", "description": "列目录"]))
        #expect(bash.category == .terminal && bash.subject == "ls -la" && bash.detail == "列目录")
        let fetch = ToolPresentation(tool: tool("WebFetch", kind: .fetch, input: ["url": "https://e.com"]))
        #expect(fetch.category == .fetch && fetch.subject == "https://e.com")
        let mcp = ToolPresentation(tool: tool("mcp__github__create_issue", kind: .other, input: ["title": "崩溃"]))
        #expect(mcp.category == .mcp && mcp.mcpServer == "github" && mcp.verb == "create_issue" && mcp.subject == "title: 崩溃")
        let task = ToolPresentation(tool: tool("Task", kind: .other, input: ["description": "调研"]))
        #expect(task.category == .subagent && task.subject == "调研")
        let child = ToolPresentation(tool: tool("", kind: .other, title: "子任务"), hasChild: true)
        #expect(child.category == .subagent)
    }

    @Test("无 rawInput 时回退到标题并去掉动词前缀")
    func fallbackToTitle() {
        let p = ToolPresentation(tool: tool("", kind: .read, title: "读取 README.md"))
        #expect(p.subject == "README.md")
        #expect(!p.subjectIsPath)
        #expect(ToolPresentation(tool: tool("", kind: .other, title: "做点什么")).subject == "做点什么")
    }

    @Test("Diff 统计")
    func diffStats() {
        let t = tool("Edit", kind: .edit, content: [.diff(path: "/a", oldText: "a\nb\nc\n", newText: "a\nB\nc\nd\n")])
        let stats = ToolPresentation.diffStats(of: t)
        #expect(stats?.added == 2)
        #expect(stats?.removed == 1)
        let created = tool("Write", kind: .edit, content: [.diff(path: "/n", oldText: nil, newText: "1\n2\n3\n")])
        #expect(ToolPresentation.diffStats(of: created)?.added == 3)
        #expect(ToolPresentation.diffStats(of: tool("Read", kind: .read)) == nil)
    }

    @Test("搜索结果解析:path:line:text 与纯路径")
    func searchParsing() {
        let hits = SearchResultParser.parse("""
        /a/b.swift:12:    // TODO: x
        Sources/c.swift:3-  context line
        /a/d.swift
        Found 3 matches
        """)
        #expect(hits.count == 3)
        #expect(hits[0].path == "/a/b.swift" && hits[0].line == 12 && hits[0].text == "// TODO: x")
        #expect(hits[1].path == "Sources/c.swift" && hits[1].line == 3)
        #expect(hits[2].path == "/a/d.swift" && hits[2].line == nil)
        #expect(SearchResultParser.parse("a\nb\nc", limit: 2).count == 0)
        #expect(SearchResultParser.parse((1...500).map { "/f\($0).swift" }.joined(separator: "\n"), limit: 50).count == 50)
    }
}

@MainActor
@Suite("时间线分组")
struct TimelineGroupingTests {
    private func store(_ steps: [(String, ToolKind, String)]) -> TimelineStore {
        let store = TimelineStore()
        for (index, step) in steps.enumerated() {
            store.apply(.toolCall(ToolCall(toolCallId: "t\(index)", name: step.0, title: step.2, kind: step.1, status: .completed, rawInput: ["file_path": .string("/f\(index)")])))
        }
        return store
    }

    @Test("连续两个以上浏览工具合并为一组")
    func groupsExploration() {
        let s = store([("Read", .read, "a"), ("Grep", .search, "b"), ("Read", .read, "c"), ("Edit", .edit, "d")])
        let items = TimelineGrouping.group(s.entries)
        #expect(items.count == 2)
        guard case .explore(let group) = items[0] else { Issue.record("应为分组"); return }
        #expect(group.toolCount == 3)
        #expect(group.summary == "已浏览 2 个文件、1 次搜索")
        #expect(!group.isRunning)
    }

    @Test("单个浏览工具不分组;思考在边缘保持独立;被其他条目打断后重新计数")
    func singleAndBoundaries() {
        let s = TimelineStore()
        s.apply(.agentThoughtChunk(messageId: nil, content: .text("想")))
        s.apply(.toolCall(ToolCall(toolCallId: "r1", name: "Read", kind: .read, status: .completed)))
        s.apply(.toolCall(ToolCall(toolCallId: "r2", name: "Read", kind: .read, status: .completed)))
        s.apply(.agentThoughtChunk(messageId: nil, content: .text("再想")))
        let items = TimelineGrouping.group(s.entries)
        // 前导思考 + 分组 + 尾部思考
        #expect(items.count == 3)
        if case .entry = items[0], case .explore = items[1], case .entry = items[2] {} else { Issue.record("结构不符") }

        let single = TimelineGrouping.group(store([("Read", .read, "a"), ("Edit", .edit, "b"), ("Read", .read, "c")]).entries)
        #expect(single.count == 3)
        #expect(single.allSatisfy { if case .entry = $0 { return true } else { return false } })
    }

    @Test("精简档:单个命令也折叠成摘要行,单个编辑保持独立;标准档不折叠")
    func compactCollapsesSingleCommand() {
        let s = TimelineStore()
        s.apply(.toolCall(ToolCall(toolCallId: "x1", name: "Bash", kind: .execute, status: .completed, rawInput: ["command": .string("python3 - <<'EOF'")])))
        let compact = TimelineGrouping.group(s.entries, density: .compact)
        guard compact.count == 1, case .explore(let group) = compact[0] else { Issue.record("单个命令应折叠为分组"); return }
        #expect(group.summary == "运行了 1 条命令")
        #expect(TimelineGrouping.group(s.entries).count == 1)
        if case .explore = TimelineGrouping.group(s.entries)[0] { Issue.record("标准档不应折叠单个命令") }

        let e = TimelineStore()
        e.apply(.toolCall(ToolCall(toolCallId: "e1", name: "Edit", kind: .edit, status: .completed, rawInput: ["file_path": .string("/a")])))
        if case .explore = TimelineGrouping.group(e.entries, density: .compact)[0] { Issue.record("单个编辑应保持独立") }
    }

    @Test("Shell 命令按意图归类:grep/find 算搜索,cat/ls 算读取,其余算运行命令")
    func shellIntent() {
        #expect(ShellIntent.classify("grep -rn foo Sources") == .search)
        #expect(ShellIntent.classify("cd /x && rg foo | head -5") == .search)
        #expect(ShellIntent.classify("rtk git status") == .run)
        #expect(ShellIntent.classify("cat a.txt") == .read)
        #expect(ShellIntent.classify("ls -la; grep x y") == .run)
        #expect(ShellIntent.classify("FOO=1 /usr/bin/find . -name x") == .search)
        #expect(ShellIntent.classify("swift build") == .run)
    }

    @Test("精简档:连续的各类工具合并为活动摘要,子 Agent 与等待授权的工具保持独立")
    func compactDensityGroupsAllTools() {
        let s = TimelineStore()
        s.apply(.toolCall(ToolCall(toolCallId: "e1", name: "Edit", kind: .edit, status: .completed, rawInput: ["file_path": .string("/a")])))
        s.apply(.toolCall(ToolCall(toolCallId: "e2", name: "Edit", kind: .edit, status: .completed, rawInput: ["file_path": .string("/b")])))
        s.apply(.toolCall(ToolCall(toolCallId: "x1", name: "Bash", kind: .execute, status: .completed, rawInput: ["command": .string("make build")])))
        s.apply(.toolCall(ToolCall(toolCallId: "x2", name: "Bash", kind: .execute, status: .completed, rawInput: ["command": .string("swift test")])))
        let standard = TimelineGrouping.group(s.entries)
        #expect(standard.count == 4)
        let compact = TimelineGrouping.group(s.entries, density: .compact)
        #expect(compact.count == 1)
        guard case .explore(let group) = compact[0] else { Issue.record("应为活动分组"); return }
        #expect(group.style == .activity)
        #expect(group.summary == "编辑了 2 个文件、运行了 2 条命令")

        // 等待授权(pending)的工具打断合并,保持可见
        let t = TimelineStore()
        t.apply(.toolCall(ToolCall(toolCallId: "a", name: "Edit", kind: .edit, status: .completed)))
        t.apply(.toolCall(ToolCall(toolCallId: "b", name: "Edit", kind: .edit, status: .pending)))
        t.apply(.toolCall(ToolCall(toolCallId: "c", name: "Edit", kind: .edit, status: .completed)))
        #expect(TimelineGrouping.group(t.entries, density: .compact).count == 3)
    }

    @Test("详细程度偏好:缺省与非法值回退标准,标题固定")
    func densityPreference() {
        let defaults = UserDefaults(suiteName: "oma.test.density.\(UUID().uuidString)") ?? .standard
        #expect(ToolDensity.current(defaults) == .standard)
        defaults.set("乱写", forKey: ToolDensity.preferenceKey)
        #expect(ToolDensity.current(defaults) == .standard)
        defaults.set("compact", forKey: ToolDensity.preferenceKey)
        #expect(ToolDensity.current(defaults) == .compact)
        #expect(ToolDensity.allCases.map(\.title) == ["精简", "标准", "详细"])
    }

    @Test("分组运行态与失败态随工具状态变化")
    func runningState() {
        let s = TimelineStore()
        s.apply(.toolCall(ToolCall(toolCallId: "a", name: "Read", kind: .read, status: .inProgress)))
        s.apply(.toolCall(ToolCall(toolCallId: "b", name: "Grep", kind: .search, status: .completed)))
        guard case .explore(let group) = TimelineGrouping.group(s.entries)[0] else { Issue.record("应为分组"); return }
        #expect(group.isRunning)
        #expect(group.summary.hasPrefix("正在浏览"))
        s.apply(.toolCallUpdate(toolCallId: "a", raw: ["status": "failed"]))
        guard case .explore(let done) = TimelineGrouping.group(s.entries)[0] else { return }
        #expect(!done.isRunning && done.hasFailure)
    }
}

@Suite("ANSI 解析")
struct ANSIParserTests {
    @Test("颜色、粗体与重置")
    func colors() {
        let spans = ANSIParser.parse("a\u{1B}[31mred\u{1B}[0m b\u{1B}[1;92mbold-green\u{1B}[0m")
        #expect(spans.map(\.text) == ["a", "red", " b", "bold-green"])
        #expect(spans[1].foreground == .basic(1))
        #expect(spans[3].foreground == .basic(10) && spans[3].bold)
        #expect(spans[0].foreground == nil)
    }

    @Test("256 色与真彩色")
    func extended() {
        let spans = ANSIParser.parse("\u{1B}[38;5;208mo\u{1B}[38;2;1;2;3mt\u{1B}[39mz")
        #expect(spans[0].foreground == .palette(208))
        #expect(spans[1].foreground == .rgb(1, 2, 3))
        #expect(spans[2].foreground == nil)
    }

    @Test("回车覆盖、OSC 与未知序列被剥离")
    func controls() {
        #expect(ANSIParser.plainText("10%\r50%\r100%\ndone") == "100%\ndone")
        #expect(ANSIParser.plainText("\u{1B}]0;title\u{07}hello\u{1B}[2K\u{1B}[1Aworld") == "helloworld")
        #expect(ANSIParser.plainText("a\r\nb") == "a\nb")
    }

    @Test("只保留末尾若干行")
    func tail() {
        let raw = (1...1000).map(String.init).joined(separator: "\n")
        let text = ANSIParser.plainText(raw, maxLines: 400)
        #expect(text.hasPrefix("601\n") && text.hasSuffix("1000"))
    }
}

@MainActor
@Suite("端到端:工具展示场景")
struct ToolShowcaseEndToEndTests {
    @Test("#showcase 一轮覆盖各类工具,呈现与分组符合预期")
    func showcaseTurn() async throws {
        let workspace = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = try await M3ScenarioTests.readyModel(workspace: workspace)
        model.send("#showcase 展示")
        #expect(await SessionModelTests.wait(timeout: .seconds(20)) { !model.isRunning && model.timeline.entries.contains { $0.kind == .assistant } })

        let tools = model.timeline.entries.compactMap(\.tool)
        #expect(tools.count == 10)
        let categories = tools.map { ToolPresentation(tool: $0).category }
        #expect(categories == [.read, .read, .search, .search, .write, .edit, .terminal, .mcp, .fetch, .terminal])
        #expect(tools.last?.status == .failed)
        #expect(tools.dropLast().allSatisfy { $0.status == .completed })

        // 前两个读取 + 两次搜索 + 联网获取:读/搜合并为一组(联网在 MCP 之后,单独成行)
        let items = TimelineGrouping.group(model.timeline.entries)
        guard case .explore(let group) = items.first(where: { if case .explore = $0 { return true } else { return false } }) else {
            Issue.record("缺少浏览分组"); return
        }
        #expect(group.toolCount == 4)
        #expect(group.summary == "已浏览 2 个文件、2 次搜索")

        // 搜索结果可解析为可点击命中
        let grep = try #require(tools.first { $0.name == "Grep" })
        var grepText = ""
        for case .content(let block) in grep.content { grepText += block.plainText ?? "" }
        #expect(SearchResultParser.parse(grepText).count == 3)
        // 写入/编辑的统计
        #expect(ToolPresentation.diffStats(of: try #require(tools.first { $0.name == "Write" }))?.added == 4)
        #expect(ToolPresentation.diffStats(of: try #require(tools.first { $0.name == "Edit" }))?.added == 2)
        model.shutdown()
    }
}
