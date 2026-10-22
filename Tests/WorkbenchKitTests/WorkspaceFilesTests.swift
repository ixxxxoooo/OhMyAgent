// @author ixxxxoooo
// 工作区文件能力测试:列举、索引忽略、模糊匹配、全局搜索。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("工作区文件")
struct WorkspaceFilesTests {
    /// 创建临时工作区并返回根路径。
    private func makeWorkspace() throws -> String {
        let root = NSTemporaryDirectory() + "oma-ws-\(UUID().uuidString)"
        let fm = FileManager.default
        for dir in ["src/deep", "node_modules/pkg", ".git", "docs"] { try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true) }
        try "func hello() {}\nlet Needle = 1\n  needle again\n".write(toFile: root + "/src/main.swift", atomically: true, encoding: .utf8)
        try "struct A {}\n".write(toFile: root + "/src/deep/Model.swift", atomically: true, encoding: .utf8)
        try "needle in deps\n".write(toFile: root + "/node_modules/pkg/index.js", atomically: true, encoding: .utf8)
        try "# 文档\n需要 Needle\n".write(toFile: root + "/docs/README.md", atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: URL(fileURLWithPath: root + "/bin.dat"))
        try "x".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        return root
    }

    @Test("目录列举:目录在前并隐藏 .git")
    func listing() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let entries = WorkspaceFiles.list(directory: root)
        #expect(!entries.contains { $0.name == ".git" })
        let firstFileIndex = entries.firstIndex { !$0.isDirectory } ?? entries.count
        let leading = entries[..<firstFileIndex]
        #expect(leading.allSatisfy { $0.isDirectory })
        #expect(entries.contains { $0.name == "src" && $0.isDirectory })
        #expect(WorkspaceFiles.list(directory: "/不存在的目录").isEmpty)
    }

    @Test("索引跳过 node_modules 与 .git")
    func indexing() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = WorkspaceFiles.index(root: root)
        #expect(files.contains("src/main.swift"))
        #expect(files.contains("src/deep/Model.swift"))
        #expect(!files.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".git") })
    }

    @Test("模糊匹配:子序列、词首与文件名优先")
    func fuzzy() {
        #expect(FuzzyMatcher.match(query: "zzz", path: "src/main.swift") == nil)
        let a = FuzzyMatcher.match(query: "mdl", path: "src/deep/Model.swift")
        #expect(a != nil)
        let ranked = FuzzyMatcher.rank(query: "main", in: ["docs/maintenance/notes.md", "src/main.swift", "a/b/c/domain.swift"])
        #expect(ranked.first?.path == "src/main.swift")
        #expect(FuzzyMatcher.rank(query: "", in: ["a", "b"]).count == 2)
        #expect(a?.positions.count == 3)
    }

    @Test("模糊匹配:ASCII 字节快路径与通用路径的得分、位置逐项一致")
    func fuzzyFastPathMatchesSlowPath() {
        let paths = [
            "src/main.swift", "src/deep/Model.swift", "docs/maintenance/notes.md", "a/b/c/domain.swift",
            "Sources/OhMyAgentApp/IDE/Shell/IDEShellView.swift", "README.md", "x_y-z.v1/Foo Bar.txt",
            "lib/HTTPServer/serverMain.rs", "m", "A/B", "src/中文/main.swift",
        ]
        let queries = ["m", "ma", "main", "MAIN", "mdl", "ide", "shell view", "fb", "hs", "zzz", "swift", "x.v", "中", "a b"]
        for query in queries {
            let fast = FuzzyMatcher.rank(query: query, in: paths, limit: 100)
            let slow = paths.compactMap { FuzzyMatcher.match(query: query, path: $0) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            #expect(fast.map(\.path) == slow.map(\.path), "查询 \(query) 排序不一致")
            #expect(fast.map(\.score) == slow.map(\.score), "查询 \(query) 得分不一致")
            #expect(fast.map(\.positions) == slow.map(\.positions), "查询 \(query) 位置不一致")
        }
    }

    @Test("模糊匹配:候选很多时的阈值截断与完整排序结果一致(含同分按路径排序)")
    func fuzzyThresholdTruncation() {
        let paths = (0..<600).map { "dir\($0 % 17)/sub\($0 % 5)/file\($0).swift" } + (0..<100).map { "m\($0).txt" }
        for query in ["m", "f", "file1", "sw", "d1"] {
            let fast = FuzzyMatcher.rank(query: query, in: paths, limit: 20)
            let slow = Array(paths.compactMap { FuzzyMatcher.match(query: query, path: $0) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }.prefix(20))
            #expect(fast.map(\.path) == slow.map(\.path), "查询 \(query) 截断后排序不一致")
            #expect(fast.map(\.positions) == slow.map(\.positions))
        }
    }

    @Test("全局搜索:忽略大小写、二进制与依赖目录")
    func searching() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let out = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "needle"))
        #expect(out.error == nil)
        let paths = out.files.map(\.path)
        #expect(paths == ["docs/README.md", "src/main.swift"])
        let main = try #require(out.files.first { $0.path == "src/main.swift" })
        #expect(main.hits.map(\.line) == [2, 3])
        #expect(main.hits[0].column == 4)
        #expect(out.totalHits == 3)
    }

    @Test("区分大小写、整词与正则")
    func options() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let cs = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "Needle", caseSensitive: true))
        #expect(cs.totalHits == 2)
        let word = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "hell", wholeWord: true))
        #expect(word.totalHits == 0)
        let re = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "func\\s+\\w+", isRegex: true))
        #expect(re.totalHits == 1)
        let bad = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "(", isRegex: true))
        #expect(bad.error != nil)
        let filtered = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "needle", pathFilter: "docs"))
        #expect(filtered.files.map(\.path) == ["docs/README.md"])
    }

    @Test("空查询返回空结果")
    func emptyQuery() async {
        let out = await WorkspaceSearch.search(root: "/tmp", options: SearchOptions(query: ""))
        #expect(out.files.isEmpty)
    }
}
