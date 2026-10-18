// @author ixxxxoooo
// 补全增强:Claude Code 内置命令清单兜底与合并、文件夹 @ 补全与序列化、分组标题。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("补全增强")
struct CompletionGroupTests {
    @Test("Agent 未通告命令时,内置清单作为兜底,且不与客户端命令重名")
    func builtinFallback() {
        let items = CompletionEngine.slashItems(query: "", agentCommands: [], limit: 200)
        let names = Set(items.map(\.insertText))
        for name in ["/compact", "/init", "/review", "/security-review", "/output-style", "/effort"] {
            #expect(names.contains(name), "缺少 \(name)")
        }
        // 经适配器实测不可用的内置命令不再推荐
        for name in ["/add-dir", "/rewind", "/todos", "/vim", "/ide", "/bug", "/pr-comments"] {
            #expect(!names.contains(name), "\(name) 不该出现在补全里")
        }
        #expect(items.count == Set(items.map(\.insertText)).count)
        #expect(items.first { $0.insertText == "/compact" }?.badge == "Claude Code")
    }

    @Test("连接后以适配器通告为准:同名去重,不再追加静态清单")
    func agentWins() {
        let commands = [AvailableCommand(name: "compact", description: "适配器说明", inputHint: nil)]
        let items = CompletionEngine.slashItems(query: "", agentCommands: commands, limit: 200)
        #expect(items.filter { $0.insertText == "/compact" }.count == 1)
        #expect(items.first { $0.insertText == "/compact" }?.subtitle == "适配器说明")
        #expect(!items.contains { $0.insertText == "/rewind" })
    }

    @Test("/usage 与 /cost 由客户端打开用量页")
    func usageIsLocal() {
        #expect(LocalCommands.parse("/usage") == .settings(page: "usage"))
        #expect(LocalCommands.parse("/cost") == .settings(page: "usage"))
    }

    @Test("@ 插入文本:文件夹带斜杠,含空白加引号")
    func mentionInsert() {
        #expect(CompletionEngine.mentionInsertText(path: "src/App.swift", isDirectory: false) == "@src/App.swift ")
        #expect(CompletionEngine.mentionInsertText(path: "src", isDirectory: true) == "@src/ ")
        #expect(CompletionEngine.mentionInsertText(path: "my docs", isDirectory: true) == "@\"my docs/\" ")
    }

    @Test("文件索引同时给出文件夹,并忽略 node_modules 等目录")
    func folderIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for dir in ["src/core", "docs", "node_modules/x"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("src/core/a.swift"), atomically: true, encoding: .utf8)
        let index = FileIndex()
        await index.prepare(root: root)
        await index.waitUntilReady()
        let dirs = await index.searchDirectories("")
        #expect(dirs.contains("src") && dirs.contains("src/core") && dirs.contains("docs"))
        #expect(!dirs.contains { $0.hasPrefix("node_modules") })
        #expect(await index.searchDirectories("cor").first == "src/core")
    }

    @Test("候选分组标题随类别变化")
    func groupTitles() {
        let file = CompletionItem(kind: .file, title: "a", insertText: "@a ")
        let folder = CompletionItem(kind: .folder, title: "d/", insertText: "@d/ ")
        #expect(file.groupTitle != folder.groupTitle)
    }
}
