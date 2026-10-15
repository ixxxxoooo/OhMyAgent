// @author ygw
// GitRepository 集成测试:在临时目录里用真实 git 建仓库,不依赖网络与用户全局配置。

import DiffKit
import Foundation
import Testing

@testable import GitKit

/// 临时仓库夹具。
private struct Fixture {
    let root: URL
    let repo: GitRepository

    /// 创建并初始化仓库(固定身份与默认分支)。
    static func make(bare: Bool = false) async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 取真实路径(/var → /private/var),与 git 输出一致
        let real = URL(fileURLWithPath: realpath(dir.path, nil).map { String(cString: $0) } ?? dir.path)
        _ = try await GitProcess.run(bare ? ["init", "--bare", "-b", "main"] : ["init", "-b", "main"], in: real)
        if !bare {
            for (k, v) in [("user.name", "Tester"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] {
                _ = try await GitProcess.run(["config", k, v], in: real)
            }
        }
        return Fixture(root: real, repo: GitRepository(root: real))
    }

    func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("GitRepository", .serialized)
struct GitRepositoryTests {
    @Test("发现仓库:子目录向上、非仓库返回 nil")
    func discover() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("sub/dir/a.txt", "x")
        let found = await GitRepository.discover(from: f.root.appendingPathComponent("sub/dir").path)
        #expect(found?.root.path == f.root.path)
        let file = await GitRepository.discover(from: f.root.appendingPathComponent("sub/dir/a.txt").path)
        #expect(file != nil)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("oma-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(await GitRepository.discover(from: outside.path) == nil)
    }

    @Test("状态→暂存→提交→取消暂存→丢弃 全流程")
    func lifecycle() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "one\ntwo\nthree\n")
        var status = try await f.repo.status()
        #expect(status.untrackedChanges.map(\.path) == ["a.txt"])
        #expect(status.headOID == nil && status.branch == "main")

        try await f.repo.stage(["a.txt"])
        status = try await f.repo.status()
        #expect(status.stagedChanges.map(\.path) == ["a.txt"] && status.stagedChanges.first?.staged == .added)
        let hash = try await f.repo.commit(message: "feat: 初始提交\n\n正文")
        #expect(hash.count == 40)
        status = try await f.repo.status()
        #expect(status.isClean && status.headOID == hash)

        try f.write("a.txt", "one\nTWO\nthree\nfour\n")
        try f.write("b.txt", "new\n")
        status = try await f.repo.status()
        #expect(status.unstagedChanges.map(\.path) == ["a.txt"])
        let stats = try await f.repo.uncommittedStats(untracked: status.untrackedChanges)
        #expect(stats == GitLineStats(added: 3, removed: 1))  // a: +2 -1;b: +1

        let diff = try #require(try await f.repo.fileDiff(path: "a.txt"))
        #expect(diff.added == 2 && diff.removed == 1)

        try await f.repo.stage(["a.txt"])
        #expect(try await f.repo.fileDiff(path: "a.txt", scope: .unstaged)?.isEmpty == true)
        #expect(try await f.repo.fileDiff(path: "a.txt", scope: .staged)?.added == 2)
        try await f.repo.unstage(["a.txt"])
        status = try await f.repo.status()
        #expect(status.stagedChanges.isEmpty && status.unstagedChanges.map(\.path) == ["a.txt"])

        try await f.repo.discard(["a.txt"], untracked: ["b.txt"])
        #expect(try f.read("a.txt") == "one\ntwo\nthree\n")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("b.txt").path))
        #expect(try await f.repo.status().isClean)
    }

    @Test("参数校验:空提交信息、危险路径与分支名被拒绝")
    func validation() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        await #expect(throws: GitError.self) { try await f.repo.commit(message: "  \n") }
        await #expect(throws: GitError.self) { try await f.repo.stage(["../outside"]) }
        await #expect(throws: GitError.self) { try await f.repo.stage(["/etc/passwd"]) }
        await #expect(throws: GitError.self) { try await f.repo.stage([]) }
        await #expect(throws: GitError.self) { try await f.repo.checkout("--detach") }
        await #expect(throws: GitError.self) { try await f.repo.createBranch("a b") }
        await #expect(throws: GitError.self) { try await f.repo.createBranch("x..y") }
    }

    @Test("无暂存内容提交失败并带 git 的提示")
    func nothingToCommit() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "x\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "init")
        do {
            try await f.repo.commit(message: "again")
            Issue.record("应当失败")
        } catch let error as GitError {
            if case .commandFailed(_, let status, _) = error { #expect(status != 0) } else { Issue.record("错误类型不对") }
        }
    }

    @Test("分支:新建、切换、列出、删除;历史与按文件历史")
    func branchesAndLog() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "1\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "c1")
        try await f.repo.createBranch("feature/x")
        try f.write("b.txt", "b\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "c2 b")
        var branches = try await f.repo.branches()
        #expect(branches.contains { $0.name == "feature/x" && $0.isCurrent })
        try await f.repo.checkout("main")
        branches = try await f.repo.branches()
        #expect(branches.contains { $0.name == "main" && $0.isCurrent })
        #expect(try await f.repo.log(limit: 10).map(\.subject) == ["c1"])
        #expect(try await f.repo.log(limit: 10, all: true).map(\.subject).sorted() == ["c1", "c2 b"])
        #expect(try await f.repo.log(path: "b.txt").isEmpty)  // main 上还没有 b.txt 的提交
        #expect(try await f.repo.log(path: "b.txt", all: true).map(\.subject) == ["c2 b"])
        try await f.repo.deleteBranch("feature/x", force: true)
        #expect(!(try await f.repo.branches()).contains { $0.name == "feature/x" })
    }

    @Test("提交文件列表、提交内 Diff 与 blame")
    func commitDetailsAndBlame() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "one\ntwo\n")
        try await f.repo.stageAll()
        let first = try await f.repo.commit(message: "first")
        try f.write("a.txt", "one\n2\n")
        try f.write("c.txt", "c\n")
        try await f.repo.stageAll()
        let second = try await f.repo.commit(message: "second")
        let files = try await f.repo.files(in: second)
        #expect(files.map(\.path).sorted() == ["a.txt", "c.txt"])
        let diff = try #require(try await f.repo.fileDiff(path: "a.txt", commit: second))
        #expect(diff.added == 1 && diff.removed == 1)
        let initial = try #require(try await f.repo.fileDiff(path: "a.txt", commit: first))
        #expect(initial.added == 2)  // 根提交没有父提交 → 视为全部新增
        let blame = try await f.repo.blame(path: "a.txt")
        #expect(blame.map(\.hash) == [first, second])
        #expect(blame.map(\.text) == ["one", "2"])
        #expect(blame[0].author == "Tester" && blame[1].summary == "second")
    }

    @Test("stash:保存(含未跟踪)、列出、弹出、丢弃")
    func stash() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "1\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "c1")
        try f.write("a.txt", "changed\n")
        try f.write("new.txt", "n\n")
        try await f.repo.stashPush(message: "我的暂存")
        #expect(try await f.repo.status().isClean)
        let list = try await f.repo.stashes()
        #expect(list.count == 1 && list[0].message.contains("我的暂存"))
        try await f.repo.stashPop()
        #expect(try f.read("a.txt") == "changed\n")
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))
        try await f.repo.stashPush()
        try await f.repo.stashDrop(index: 0)
        #expect(try await f.repo.stashes().isEmpty)
    }

    @Test("推送/拉取:无上游时自动设置上游,落后后可拉取")
    func pushPull() async throws {
        let remote = try await Fixture.make(bare: true)
        let a = try await Fixture.make()
        let b = try await Fixture.make()
        defer { remote.cleanup(); a.cleanup(); b.cleanup() }
        _ = try await GitProcess.run(["remote", "add", "origin", remote.root.path], in: a.root)
        try a.write("a.txt", "1\n")
        try await a.repo.stageAll()
        try await a.repo.commit(message: "c1")
        try await a.repo.push()
        var status = try await a.repo.status()
        #expect(status.upstream == "origin/main" && status.ahead == 0)

        _ = try await GitProcess.run(["remote", "add", "origin", remote.root.path], in: b.root)
        _ = try await GitProcess.run(["pull", "origin", "main"], in: b.root)
        try b.write("b.txt", "2\n")
        try await b.repo.stageAll()
        try await b.repo.commit(message: "c2 from b")
        _ = try await GitProcess.run(["push", "origin", "main"], in: b.root)

        try await a.repo.fetch()
        status = try await a.repo.status()
        #expect(status.behind == 1)
        try await a.repo.pull()
        #expect(try await a.repo.status().behind == 0)
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("b.txt").path))
    }

    @Test("冲突:合并产生冲突,采用对方后标记解决")
    func conflicts() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try f.write("a.txt", "base\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "base")
        try await f.repo.createBranch("other")
        try f.write("a.txt", "other change\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "other")
        try await f.repo.checkout("main")
        try f.write("a.txt", "main change\n")
        try await f.repo.stageAll()
        try await f.repo.commit(message: "main")
        let merge = try await GitProcess.run(["merge", "other"], in: f.root)
        #expect(merge.status != 0)
        var status = try await f.repo.status()
        #expect(status.conflicts.map(\.path) == ["a.txt"])
        try await f.repo.resolve("a.txt", with: .theirs)
        #expect(try f.read("a.txt") == "other change\n")
        status = try await f.repo.status()
        #expect(status.conflicts.isEmpty)
        #expect(status.stagedChanges.map(\.path) == ["a.txt"])
    }

    @Test("二进制文件的 Diff 返回 nil")
    func binary() async throws {
        let f = try await Fixture.make()
        defer { f.cleanup() }
        try Data([0, 1, 2, 3, 0, 255]).write(to: f.root.appendingPathComponent("bin.dat"))
        try await f.repo.stageAll()
        try await f.repo.commit(message: "bin")
        try Data([0, 9, 9]).write(to: f.root.appendingPathComponent("bin.dat"))
        #expect(try await f.repo.fileDiff(path: "bin.dat") == nil)
    }
}
