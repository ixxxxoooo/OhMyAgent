// @author ixxxxoooo
// 搜索索引测试:三元组与正则字面量提取、索引结果与全量扫描一致、增量更新、性能基线。

import Foundation
import Testing

@testable import WorkbenchKit

@Suite("搜索索引")
struct SearchIndexTests {
    private func makeRoot(files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-search-\(UUID().uuidString)").path
        for (rel, text) in files {
            let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func hits(_ output: SearchOutput) -> [String] {
        output.files.flatMap { file in file.hits.map { "\(file.path):\($0.line)" } }.sorted()
    }

    @Test("三元组:小写化、去重、过短为空")
    func trigrams() {
        #expect(SearchIndex.trigrams(of: "ab").isEmpty)
        #expect(SearchIndex.trigrams(of: "AbCabc").count == 3) // abc / bca / cab
    }

    @Test("正则字面量提取:保守,量词、分组、分支都不会造成漏检")
    func requiredLiterals() {
        #expect(SearchIndex.requiredLiterals(of: "func\\s+\\w+Handler") == ["func", "handler"])
        #expect(SearchIndex.requiredLiterals(of: "foo|bar") == nil)
        // 被 ? 修饰的最后一个字符不算必需:colou?r → "colo"(r 不足三字符)
        #expect(SearchIndex.requiredLiterals(of: "colou?r") == ["colo"])
        // 被 * 修饰的字符不算必需:abc*def → "ab" 不足三字符,只剩 "def"
        #expect(SearchIndex.requiredLiterals(of: "abc*def") == ["def"])
        // 分组内容整体忽略
        #expect(SearchIndex.requiredLiterals(of: "(optional)?needle") == ["needle"])
        // 转义的标点是字面量
        #expect(SearchIndex.requiredLiterals(of: "a\\.b\\.c") == ["a.b.c"])
        // 字符类内的内容不参与
        #expect(SearchIndex.requiredLiterals(of: "[xyz]+hello") == ["hello"])
        // 大括号量词修饰前一个字符
        #expect(SearchIndex.requiredLiterals(of: "abcd{2,3}") == ["abc"])
    }

    @Test("数组交集与二分")
    func arrays() {
        #expect(SearchIndex.intersect([1, 3, 5, 7], [3, 4, 5, 8]) == [3, 5])
        #expect(SearchIndex.intersect([], [1]).isEmpty)
        #expect(SearchIndex.lowerBound([1, 3, 5], 4) == 2)
        #expect(SearchIndex.lowerBound([1, 3, 5], 9) == 3)
    }

    @Test("索引搜索与全量扫描结果一致,且扫描文件更少")
    func matchesFullScan() async throws {
        var files: [String: String] = [:]
        for i in 0..<60 { files["src/file\(i).swift"] = "import Foundation\nfunc work\(i)() { print(\"filler \(i)\") }\n" }
        files["src/Target.swift"] = "struct NeedleHandler {\n    func findNeedle() {}\n}\n"
        files["docs/notes.md"] = "The NEEDLE is here\nanother needle line\n"
        files["bin/data.bin"] = "needle\u{0}binary"
        let root = try makeRoot(files: files)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let list = WorkspaceFiles.index(root: root)
        let index = SearchIndex(root: root)
        await index.sync(files: list)
        await index.waitUntilReady()
        #expect(await index.isReady)

        let queries = [
            SearchOptions(query: "needle"),
            SearchOptions(query: "Needle", caseSensitive: true),
            SearchOptions(query: "needle", wholeWord: true),
            SearchOptions(query: "func\\s+find\\w+", isRegex: true),
            SearchOptions(query: "needle|filler 7", isRegex: true),
            SearchOptions(query: "ne", caseSensitive: false),
            SearchOptions(query: "needle", pathFilter: "docs"),
        ]
        for options in queries {
            let plain = await WorkspaceSearch.search(root: root, options: options, files: list)
            let indexed = await WorkspaceSearch.search(root: root, options: options, files: list, index: index)
            #expect(hits(plain) == hits(indexed), "查询 \(options.query) 结果应一致")
        }
        let narrowed = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "NeedleHandler"), files: list, index: index)
        #expect(narrowed.indexed)
        #expect(narrowed.scannedFiles <= 2, "只应扫描含该词的文件,实际 \(narrowed.scannedFiles)")
        let short = await WorkspaceSearch.search(root: root, options: SearchOptions(query: "ne"), files: list, index: index)
        #expect(!short.indexed, "过短的查询没有三元组,回退全量扫描")
    }

    @Test("增量更新:修改、新增、删除都能被后续查询看到")
    func incremental() async throws {
        let root = try makeRoot(files: ["a.txt": "alpha content\n", "b.txt": "beta content\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let index = SearchIndex(root: root)
        var list = WorkspaceFiles.index(root: root)
        await index.sync(files: list)
        await index.waitUntilReady()

        func search(_ query: String) async -> [String] {
            list = WorkspaceFiles.index(root: root)
            await index.sync(files: list, force: true)
            return hits(await WorkspaceSearch.search(root: root, options: SearchOptions(query: query), files: list, index: index))
        }

        #expect(await search("zebra").isEmpty)
        // 修改已有文件(大小变化)
        try "alpha content\nzebra appears now\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(await search("zebra") == ["a.txt:2"])
        // 新增文件
        try "zebra again\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        #expect(await search("zebra") == ["a.txt:2", "c.txt:1"])
        // 删除文件
        try FileManager.default.removeItem(atPath: root + "/a.txt")
        #expect(await search("zebra") == ["c.txt:1"])
        // 内容被改掉后旧词不再命中
        try "something else\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8)
        #expect(await search("zebra").isEmpty)
        #expect(await index.indexedFileCount == 2)
    }

    @Test("性能基线:3000 个文件,索引查询只扫描极少文件且不慢于全量扫描")
    func performanceBaseline() async throws {
        var files: [String: String] = [:]
        for i in 0..<3000 {
            files["pkg\(i % 30)/module\(i).swift"] = (0..<40).map { "let value\(i)_\($0) = compute(\($0)) // line filler text for realism" }.joined(separator: "\n")
        }
        files["pkg7/Unique.swift"] = "let marker = \"zzUniqueMarkerQQ\"\n"
        let root = try makeRoot(files: files)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let list = WorkspaceFiles.index(root: root)
        let index = SearchIndex(root: root)
        let buildStart = ContinuousClock.now
        await index.sync(files: list)
        await index.waitUntilReady()
        let buildMs = (ContinuousClock.now - buildStart).seconds * 1000

        let options = SearchOptions(query: "zzUniqueMarkerQQ")
        let plainStart = ContinuousClock.now
        let plain = await WorkspaceSearch.search(root: root, options: options, files: list)
        let plainMs = (ContinuousClock.now - plainStart).seconds * 1000
        await index.sync(files: list, force: true)
        let indexedStart = ContinuousClock.now
        let indexed = await WorkspaceSearch.search(root: root, options: options, files: list, index: index)
        let indexedMs = (ContinuousClock.now - indexedStart).seconds * 1000
        print("【基线】索引构建 \(Int(buildMs)) ms;全量扫描 \(Int(plainMs)) ms;索引查询 \(Int(indexedMs)) ms(含同步);扫描文件 \(indexed.scannedFiles)/\(list.count)")
        #expect(hits(plain) == hits(indexed))
        #expect(indexed.scannedFiles <= 3)
    }
}

private extension Duration {
    /// 秒数(含小数)。
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
