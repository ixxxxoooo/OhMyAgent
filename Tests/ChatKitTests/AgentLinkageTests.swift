// @author ygw
// Agent↔编辑器联动:首个改动行定位、`@文件:行范围` 引用解析。

import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("Agent 联动")
struct AgentLinkageTests {
    @Test("首个改动行:新增、中间插入、只删除、新建、无改动")
    func firstChangedLine() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh"
        #expect(SessionModel.firstChangedLine(old: old, new: "a\nb\nc\nX\ne\nf\ng\nh") == 4)
        #expect(SessionModel.firstChangedLine(old: old, new: "a\nb\nc\nd\ne\nf\ng\nh\ni") == 9)
        #expect(SessionModel.firstChangedLine(old: old, new: "a\nb\nd\ne\nf\ng\nh") == 3)
        #expect(SessionModel.firstChangedLine(old: nil, new: "x\ny") == 1)
        #expect(SessionModel.firstChangedLine(old: old, new: old) == nil)
    }

    @Test("行号后缀:存在的同名文件优先,否则去掉 :N / :N-M")
    func stripLineSuffix() throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try "x".write(to: ws.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "y".write(to: ws.appendingPathComponent("odd:12"), atomically: true, encoding: .utf8)
        #expect(CompletionEngine.stripLineSuffix("a.swift:12", workspace: ws) == "a.swift")
        #expect(CompletionEngine.stripLineSuffix("a.swift:12-20", workspace: ws) == "a.swift")
        #expect(CompletionEngine.stripLineSuffix("a.swift", workspace: ws) == "a.swift")
        #expect(CompletionEngine.stripLineSuffix("a.swift:x", workspace: ws) == "a.swift:x")
        #expect(CompletionEngine.stripLineSuffix("a.swift:1-2-3", workspace: ws) == "a.swift:1-2-3")
        #expect(CompletionEngine.stripLineSuffix("odd:12", workspace: ws) == "odd:12")
    }

    @Test("@文件:行范围 会被解析为该文件的资源链接")
    func mentionWithLineRange() throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "x".write(to: ws.appendingPathComponent("Sources/a.swift"), atomically: true, encoding: .utf8)
        let files = CompletionEngine.mentionedFiles(in: "看看 @Sources/a.swift:3-9, 以及 @Sources/a.swift:12 还有 @Sources/none.swift:1", workspace: ws)
        #expect(files.map(\.lastPathComponent) == ["a.swift"])
    }

    @Test("Agent 编辑:回调给出路径与首个改动行,汇总发布与回退都会推进 changesRevision")
    func agentEditCallbackAndRevision() async throws {
        let ws = try M3ScenarioTests.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let file = ws.appendingPathComponent("oma-demo.txt")
        try (1...10).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let model = try await M3ScenarioTests.readyModel(workspace: ws)
        var edits: [AgentEdit] = []
        model.onAgentEdit = { edits.append($0) }
        let before = model.changesRevision
        model.send("#edit")
        #expect(await SessionModelTests.wait { !model.pendingPermissions.isEmpty })
        model.resolve(try #require(model.pendingPermissions.first), optionId: "allow")
        #expect(await SessionModelTests.wait { !model.isRunning && model.timeline.entries.contains { $0.kind == .changes } })
        #expect(edits.count == 1)
        #expect(edits.first?.path.hasSuffix("oma-demo.txt") == true)
        #expect(edits.first?.firstChangedLine == 3)
        #expect(model.changesRevision == before + 1)

        let change = try #require(model.timeline.entries.first { $0.kind == .changes }?.changes.first)
        model.revert(change)
        #expect(await SessionModelTests.wait { change.status == .reverted })
        #expect(model.changesRevision == before + 2)
        model.shutdown()
    }
}
