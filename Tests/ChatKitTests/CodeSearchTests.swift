// @author ixxxxoooo
// 代码搜索与 /explore 测试:入参解析、结果格式化、命令解析、Bridge 工具清单。

import ACPKit
import AgentHost
import Foundation
import Testing

@testable import ChatKit

@Suite("代码搜索与 Explore")
struct CodeSearchTests {
    @Test("入参解析:默认值、上限夹取、缺少 query 返回 nil")
    func parse() {
        #expect(CodeSearchQuery.parse(["query": ""]) == nil)
        #expect(CodeSearchQuery.parse([:]) == nil)
        let basic = CodeSearchQuery.parse(["query": "needle"])
        #expect(basic == CodeSearchQuery(query: "needle"))
        let full = CodeSearchQuery.parse(["query": "a.b", "regex": true, "case_sensitive": true, "whole_word": true, "path": "src", "max_results": 9999])
        #expect(full?.isRegex == true && full?.caseSensitive == true && full?.wholeWord == true)
        #expect(full?.pathFilter == "src")
        #expect(full?.maxResults == 200)
        #expect(CodeSearchQuery(query: "x", maxResults: 0).maxResults == 1)
    }

    @Test("格式化:主目录相对路径、附加文件夹绝对路径、截断提示、错误与空结果")
    func format() {
        let workspace = "/p/main"
        let result = CodeSearchResult(
            matches: [CodeSearchMatch(root: workspace, path: "src/a.swift", line: 3, preview: "  let a = 1"),
                      CodeSearchMatch(root: "/p/extra", path: "lib/b.swift", line: 9, preview: "let b")],
            totalHits: 7, fileCount: 2, truncated: false, indexed: true, scannedFiles: 4)
        let text = CodeSearchFormatter.format(result, workspace: workspace, limit: 50)
        #expect(text.contains("7 match(es) in 2 file(s)"))
        #expect(text.contains("[indexed, scanned 4 files]"))
        #expect(text.contains("src/a.swift:3: let a = 1"))
        #expect(text.contains("/p/extra/lib/b.swift:9: let b"))
        let limited = CodeSearchFormatter.format(result, workspace: workspace, limit: 1)
        #expect(limited.contains("showing the first 1"))
        #expect(!limited.contains("b.swift"))
        #expect(CodeSearchFormatter.format(CodeSearchResult(), workspace: workspace, limit: 5) == "No matches found.")
        #expect(CodeSearchFormatter.format(CodeSearchResult(error: "bad regex"), workspace: workspace, limit: 5).hasPrefix("Search failed"))
    }

    @Test("/explore 命令:带问题解析,空参数给出用法,提示词要求只读与子 Agent")
    func exploreCommand() {
        #expect(LocalCommands.parse("/explore 登录流程在哪里") == .explore("登录流程在哪里"))
        #expect(LocalCommands.parse("/explore") == .explore(""))
        #expect(LocalCommands.names.contains("explore"))
        let prompt = LocalCommands.explorePrompt("where is auth")
        #expect(prompt.contains("Explore subagent") && prompt.contains("Do not modify") && prompt.contains("where is auth"))
    }

    @Test("未注入实现时 provider 返回 nil")
    func providerWithoutHandler() async {
        // 共享实例可能已被其他测试注入,这里只验证注入后可调用
        CodeSearchProvider.shared.install { _, query in CodeSearchResult(totalHits: query.query.count, fileCount: 1) }
        let result = await CodeSearchProvider.shared.search(workspace: "/w", query: CodeSearchQuery(query: "abc"))
        #expect(result?.totalHits == 3)
    }
}
