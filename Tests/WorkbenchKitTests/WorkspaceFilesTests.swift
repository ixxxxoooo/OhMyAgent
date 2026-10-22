// @author ixxxxoooo
// 工作区文件能力测试:列举、索引忽略、模糊匹配、全局搜索。

import ChatKit
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

@Suite("模糊匹配预判")
struct FuzzyPrefilterTests {
    @Test("预判与完整匹配的子序列条件一致;含非 ASCII 的路径返回 nil")
    func mayMatchAgreesWithMatch() {
        let paths = ["Sources/App/Main.swift", "README.md", "docs/设计文档.md", "a/b/c_d-e.f", "UPPER/Case.TXT", ""]
        let queries = ["main", "rdm", "sam", "ABC", "cd", "txt", "zzz", "m s", "设计"]
        for query in queries {
            for path in paths {
                let expected = FuzzyMatcher.match(query: query, path: path) != nil
                guard let prepared = FuzzyMatcher.preparedQuery(query) else { continue }
                guard let predicted = FuzzyMatcher.mayMatch(preparedQuery: prepared, path: path) else {
                    #expect(path.utf8.contains { $0 >= 0x80 }, "只有含非 ASCII 的路径才返回 nil")
                    continue
                }
                #expect(predicted == expected, "查询 \(query) 路径 \(path)")
            }
        }
        #expect(FuzzyMatcher.preparedQuery("设计") == nil)
        #expect(FuzzyMatcher.preparedQuery("  ") == nil)
    }
}

@Suite("文件索引增量更新与 .gitignore")
struct IncrementalIndexTests {
    /// 造一个临时工作区。
    private func makeRoot(_ files: [String]) throws -> String {
        let root = NSTemporaryDirectory() + "oma-incr-\(UUID().uuidString)"
        for file in files {
            let path = root + "/" + file
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        }
        return root
    }

    @Test("增量更新:新增、删除、重命名、新子目录、删除目录都与整树重建一致")
    func incrementalMatchesFullIndex() throws {
        let root = try makeRoot(["a.txt", "src/main.swift", "src/util/helper.swift", "docs/readme.md", "node_modules/pkg/x.js"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        var index = WorkspaceFiles.index(root: root, ignore: IndexIgnore.none)
        let fm = FileManager.default
        // 一批改动:根目录新增文件、src 内重命名、新建深层目录、删除整个 docs
        fm.createFile(atPath: root + "/b.txt", contents: Data())
        try fm.moveItem(atPath: root + "/src/main.swift", toPath: root + "/src/app.swift")
        try fm.createDirectory(atPath: root + "/new/deep/er", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/new/deep/er/f.txt", contents: Data())
        try fm.removeItem(atPath: root + "/docs")
        fm.createFile(atPath: root + "/node_modules/pkg/y.js", contents: Data())
        let changed: Set<String> = [root, root + "/src", root + "/new", root + "/docs", root + "/node_modules/pkg"]
        guard let updated = WorkspaceFiles.applyingChanges(to: index, root: root, directories: changed, ignore: IndexIgnore.none) else {
            Issue.record("应能增量更新"); return
        }
        index = updated
        #expect(index == WorkspaceFiles.index(root: root, ignore: IndexIgnore.none))
        #expect(index.contains("new/deep/er/f.txt") && index.contains("src/app.swift") && index.contains("b.txt"))
        #expect(!index.contains { $0.hasPrefix("docs/") } && !index.contains { $0.hasPrefix("node_modules/") })
    }

    @Test("目录过多或不在工作区内时返回 nil,由调用方整树重建")
    func fallsBackWhenNotApplicable() throws {
        let root = try makeRoot(["a.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let many = Set((0...WorkspaceFiles.maxIncrementalDirectories).map { root + "/d\($0)" })
        #expect(WorkspaceFiles.applyingChanges(to: [], root: root, directories: many, ignore: IndexIgnore.none) == nil)
        #expect(WorkspaceFiles.applyingChanges(to: [], root: root, directories: ["/elsewhere/x"], ignore: IndexIgnore.none) == nil)
    }

    @Test(".gitignore:忽略规则生效,取反规则跳过,偏好关闭后不读取")
    func gitignoreRules() throws {
        let root = try makeRoot(["keep.swift", "debug.log", "out/gen.swift", "src/a.log", "src/b.swift"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "# 注释\n*.log\n/out/\n!important.log\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "oma-gitignore-\(UUID().uuidString)") ?? .standard
        let on = WorkspaceFiles.index(root: root, ignore: IndexIgnore.current(root: root, defaults))
        #expect(!on.contains("debug.log") && !on.contains("src/a.log") && !on.contains("out/gen.swift"))
        #expect(on.contains("keep.swift") && on.contains("src/b.swift") && on.contains(".gitignore"))
        defaults.set(false, forKey: IndexIgnore.gitignorePreferenceKey)
        let off = WorkspaceFiles.index(root: root, ignore: IndexIgnore.current(root: root, defaults))
        #expect(off.contains("debug.log") && off.contains("out/gen.swift"))
    }
}
