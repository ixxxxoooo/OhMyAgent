// @author ixxxxoooo
// 演示项目生成测试:用 GitKit 回读生成的仓库,验证提交历史、分支、标签、stash、工作区各类改动与冲突。

import Foundation
import GitKit
import Testing
@testable import DemoKit

/// 生成到临时沙盒(每个测试套件只生成一次,避免重复耗时)。
private actor Sandbox {
    static let shared = Sandbox()
    private var cached: (DemoPaths, [DemoProjectInfo])?

    func get() async throws -> (DemoPaths, [DemoProjectInfo]) {
        if let cached { return cached }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-test-\(UUID().uuidString)")
        let paths = DemoPaths(root: root)
        let infos = try await DemoWorkspace.materialize(paths: paths)
        cached = (paths, infos)
        return (paths, infos)
    }
}

@Suite("演示项目生成", .serialized)
struct DemoWorkspaceTests {
    @Test("沙盒路径:环境变量覆盖,默认落在 Caches 下")
    func paths() {
        let custom = DemoPaths.resolve(environment: ["OMA_DEMO_ROOT": "/tmp/oma-demo-x"])
        #expect(custom.root.path == "/tmp/oma-demo-x")
        #expect(custom.workbenchFile.path == "/tmp/oma-demo-x/support/workbench.json")
        let fallback = DemoPaths.resolve(environment: [:])
        #expect(fallback.root.path.hasSuffix("Library/Caches/OhMyAgent/Demo"))
    }

    @Test("生成全部演示项目,Git 与非 Git 目录各就位")
    func projects() async throws {
        let (paths, infos) = try await Sandbox.shared.get()
        #expect(infos.map(\.name) == ["atlas-web", "notes-cli", "merge-lab", "legacy-api", "empty-project", "perf-longchat", "perf-render", "perf-multitab"])
        for info in infos { #expect(FileManager.default.fileExists(atPath: info.path)) }
        #expect(await GitRepository.discover(from: paths.project("legacy-api").path) == nil)
        #expect(await GitRepository.discover(from: paths.project("empty-project").path) == nil)
        #expect(await GitRepository.discover(from: paths.project("atlas-web").path) != nil)
    }

    /// 递归统计常规文件数(同步函数,避免在异步上下文里使用 NSEnumerator)。
    private static func countFiles(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        return count
    }

    @Test("性能实验室:perf-multitab 含 1 万文件的深层目录与 Git 历史,perf-render 有大素材")
    func perfLab() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let deep = paths.project("perf-multitab/perf-fs")
        #expect(Self.countFiles(in: deep) == DemoPerfProjects.deepFileCount)
        let repo = GitRepository(root: paths.project("perf-multitab"))
        #expect(try await repo.log(limit: 10).count == 3)
        let status = try await repo.status()
        #expect(status.changes.contains { $0.path == "docs/guide.md" })
        let csv = try String(contentsOf: paths.project("perf-render/data/metrics.csv"), encoding: .utf8)
        #expect(csv.split(separator: "\n").count == 3_001)
        #expect(FileManager.default.fileExists(atPath: paths.project("perf-render/assets/logo.png").path))
        #expect(FileManager.default.fileExists(atPath: paths.project("perf-longchat/README.md").path))
        // IDE 实验室:大文件与多语言样例
        #expect(FileManager.default.fileExists(atPath: paths.project("perf-multitab/ide-lab/big/Big50k.swift").path))
        #expect(FileManager.default.fileExists(atPath: paths.project("perf-multitab/ide-lab/lang/sample.rs").path))
    }

    @Test("atlas-web:提交历史、作者、合并提交、分支与标签")
    func atlasHistory() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let repo = GitRepository(root: paths.project("atlas-web"))
        let all = try await repo.log(limit: 200, all: true)
        #expect(all.count >= 25)
        #expect(Set(all.map(\.author)) == ["林雨", "陈墨", "Wen Jiao"])
        #expect(all.contains { $0.isMerge })
        let branches = try await repo.branches().filter { !$0.isRemote }.map(\.name)
        #expect(Set(branches) == ["main", "feature/metrics", "fix/router-case", "feature/ui-polish"])
        let refs = all.flatMap(\.refs).joined(separator: " ")
        for tag in ["v0.1.0", "v0.2.0", "v0.3.0"] { #expect(refs.contains(tag)) }
    }

    @Test("atlas-web:工作区含已暂存/未暂存/未跟踪/重命名/删除,并领先远端 1 个提交")
    func atlasWorkingTree() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let repo = GitRepository(root: paths.project("atlas-web"))
        let status = try await repo.status()
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
        #expect(!status.stagedChanges.isEmpty)
        #expect(!status.unstagedChanges.isEmpty)
        #expect(status.untrackedChanges.count == 2)
        #expect(status.conflicts.isEmpty)
        #expect(status.changes.contains { $0.path == "Sources/AtlasCore/Legacy.swift" && $0.unstaged != nil })
        #expect(status.changes.contains { $0.originalPath == "Sources/AtlasCore/Util.swift" })
        // README 同时有已暂存与未暂存两种状态
        let readme = try #require(status.changes.first { $0.path == "README.md" })
        #expect(readme.staged != nil && readme.unstaged != nil)
    }

    @Test("atlas-web:两个 stash,blame 能区分多位作者")
    func atlasStashAndBlame() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let repo = GitRepository(root: paths.project("atlas-web"))
        let stashes = try await repo.stashes()
        #expect(stashes.count == 2)
        let blame = try await repo.blame(path: "Sources/AtlasCore/Session.swift")
        #expect(Set(blame.map(\.author)).count >= 2)
    }

    @Test("notes-cli 干净,merge-lab 处于合并冲突")
    func cleanAndConflict() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let clean = try await GitRepository(root: paths.project("notes-cli")).status()
        #expect(clean.isClean)
        let conflict = try await GitRepository(root: paths.project("merge-lab")).status()
        #expect(Set(conflict.conflicts.map(\.path)) == ["config.yaml", "calc.py"])
        #expect(conflict.untrackedChanges.count == 1)
    }

    @Test("版本一致时复用已有沙盒,reset 才重建")
    func reuseAndReset() async throws {
        let (paths, _) = try await Sandbox.shared.get()
        let probe = paths.project("empty-project").appendingPathComponent("probe.txt")
        try "x".write(to: probe, atomically: true, encoding: .utf8)
        _ = try await DemoWorkspace.materialize(paths: paths)
        #expect(FileManager.default.fileExists(atPath: probe.path))   // 复用,没被清掉
        _ = try await DemoWorkspace.materialize(paths: paths, reset: true)
        #expect(!FileManager.default.fileExists(atPath: probe.path))  // 重建
        #expect(try await GitRepository(root: paths.project("atlas-web")).status().ahead == 1)
    }

    @Test("同样的输入得到同样的提交哈希(确定性)")
    func deterministic() async throws {
        let rootA = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-det-a-\(UUID().uuidString)")
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("oma-demo-det-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = DemoPaths(root: rootA), b = DemoPaths(root: rootB)
        _ = try await DemoWorkspace.materialize(paths: a)
        _ = try await DemoWorkspace.materialize(paths: b)
        let logA = try await GitRepository(root: a.project("notes-cli")).log(limit: 50).map(\.hash)
        let logB = try await GitRepository(root: b.project("notes-cli")).log(limit: 50).map(\.hash)
        #expect(!logA.isEmpty)
        #expect(logA == logB)
    }
}
