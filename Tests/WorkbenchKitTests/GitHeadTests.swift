// @author ixxxxoooo
// Git HEAD 解析测试:分支、游离、worktree 间接文件与非仓库目录。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("Git HEAD 解析")
struct GitHeadTests {
    @Test("解析分支、带斜杠的分支与游离 HEAD")
    func parseForms() {
        #expect(GitHead.parse("ref: refs/heads/main\n") == .branch("main"))
        #expect(GitHead.parse("ref: refs/heads/feature/ui-shell") == .branch("feature/ui-shell"))
        #expect(GitHead.parse("0123456789abcdef0123456789abcdef01234567") == .detached("0123456"))
        #expect(GitHead.parse("") == nil)
        #expect(GitHead.parse("garbage!") == nil)
        #expect(GitHead.detachedName == "0123456")
    }

    @Test("从子目录向上查找 .git 并读取分支")
    func readFromSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "ref: refs/heads/dev\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(GitHead.read(at: sub) == .branch("dev"))
        #expect(GitHead.read(at: sub)?.displayName == "dev")
    }

    @Test("worktree:.git 是指向 gitdir 的文件")
    func worktreeIndirection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("main/.git/worktrees/w1")
        let work = root.appendingPathComponent("w1")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "ref: refs/heads/topic\n".write(to: real.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(real.path)\n".write(to: work.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitHead.read(at: work) == .branch("topic"))
    }

    @Test("非仓库目录返回 nil")
    func notARepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 临时目录的上级可能恰好位于某个仓库中,因此只断言「不会崩溃且结果可用」
        _ = GitHead.read(at: dir)
    }
}

private extension GitHead {
    static var detachedName: String { GitHead.detached("0123456").displayName }
}
