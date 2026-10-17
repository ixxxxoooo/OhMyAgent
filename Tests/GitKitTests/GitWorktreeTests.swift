// @author ixxxxoooo
// 工作树测试:porcelain 与 shortstat 解析、真实仓库里新增/合并/删除。

import Foundation
import Testing

@testable import GitKit

@Suite("Git 工作树")
struct GitWorktreeTests {
    @Test("解析 porcelain:主检出、分支、游离、锁定与可清理")
    func parse() {
        let text = """
        worktree /repo
        HEAD aaaaaaa
        branch refs/heads/main

        worktree /wt/feature
        HEAD bbbbbbb
        branch refs/heads/oma/feature

        worktree /wt/detached
        HEAD ccccccc
        detached
        locked in use

        worktree /wt/gone
        HEAD ddddddd
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        let list = GitParsers.parseWorktrees(text)
        #expect(list.count == 4)
        #expect(list[0].isMain && list[0].branch == "main" && list[0].path == "/repo")
        #expect(!list[1].isMain && list[1].branch == "oma/feature")
        #expect(list[2].branch == nil && list[2].isLocked)
        #expect(list[3].isPrunable)
        #expect(GitParsers.parseWorktrees("").isEmpty)
    }

    @Test("解析 shortstat")
    func shortStat() {
        #expect(GitParsers.parseShortStat(" 3 files changed, 10 insertions(+), 2 deletions(-)\n") == GitShortStat(files: 3, insertions: 10, deletions: 2))
        #expect(GitParsers.parseShortStat(" 1 file changed, 1 insertion(+)\n") == GitShortStat(files: 1, insertions: 1, deletions: 0))
        #expect(GitParsers.parseShortStat("") == GitShortStat())
    }

    private func makeRepo() async throws -> (repo: GitRepository, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: GitRepository.realPath(dir.path))
        _ = try await GitProcess.run(["init", "-b", "main"], in: real)
        for (k, v) in [("user.name", "Tester"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] {
            _ = try await GitProcess.run(["config", k, v], in: real)
        }
        try "hello\n".write(to: real.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let repo = GitRepository(root: real)
        try await repo.stageAll()
        _ = try await repo.commit(message: "init")
        return (repo, { try? FileManager.default.removeItem(at: real) })
    }

    @Test("新增工作树、在其中提交、合并回主检出、删除")
    func lifecycle() async throws {
        let (repo, cleanup) = try await makeRepo()
        defer { cleanup() }
        let wtPath = repo.root.path + "-wt/feature"
        defer { try? FileManager.default.removeItem(atPath: repo.root.path + "-wt") }

        let wt = try await repo.addWorktree(at: wtPath, branch: "oma/feature")
        var list = try await repo.worktrees()
        #expect(list.count == 2)
        #expect(list.first { $0.branch == "oma/feature" } != nil)
        #expect(list.first?.isMain == true)

        // 在工作树里改动并提交
        let base = try #require(await repo.headCommit())
        try "hello\nfrom worktree\n".write(toFile: wtPath + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: wtPath + "/b.txt", atomically: true, encoding: .utf8)
        let status = try await wt.status()
        #expect(status.changes.count == 2)
        try await wt.stageAll()
        _ = try await wt.commit(message: "work in worktree")
        let stat = try await wt.shortStat(from: base)
        #expect(stat.files == 2 && stat.insertions == 2)

        // 主检出未受影响,合并后得到改动
        #expect(!FileManager.default.fileExists(atPath: repo.root.path + "/b.txt"))
        try await repo.merge(branch: "oma/feature")
        #expect(FileManager.default.fileExists(atPath: repo.root.path + "/b.txt"))

        try await repo.removeWorktree(at: wtPath)
        list = try await repo.worktrees()
        #expect(list.count == 1)
        try await repo.deleteBranch("oma/feature")
    }

    @Test("参数校验:非法分支名与相对路径被拒绝")
    func validation() async throws {
        let (repo, cleanup) = try await makeRepo()
        defer { cleanup() }
        await #expect(throws: GitError.self) { try await repo.addWorktree(at: "/tmp/x-oma-invalid", branch: "-bad") }
        await #expect(throws: GitError.self) { try await repo.addWorktree(at: "relative/path", branch: "ok") }
        await #expect(throws: GitError.self) { try await repo.removeWorktree(at: "relative") }
    }
}
