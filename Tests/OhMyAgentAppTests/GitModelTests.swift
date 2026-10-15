// @author ygw
// GitModel 测试:真实临时仓库上的刷新、暂存、提交、分支与错误处理。

import Foundation
import GitKit
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Git 视图模型", .serialized)
struct GitModelTests {
    private func makeRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "oma-gm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let script = "cd '\(dir)' && git init -q -b main && git config user.name T && git config user.email t@x.com && git config commit.gpgsign false"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        return dir
    }

    @Test("非仓库目录:阶段为 notRepository,可初始化")
    func notRepository() async throws {
        let dir = NSTemporaryDirectory() + "oma-gm-none-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let model = GitModel(projectPath: dir)
        await model.refresh()
        #expect(model.phase == .notRepository)
        await model.initializeRepository()
        #expect(model.phase == .ready)
        #expect(model.status.branch == "main")
    }

    @Test("刷新→暂存→提交(无暂存时自动暂存全部)→状态干净")
    func commitFlow() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "hello\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let model = GitModel(projectPath: dir)
        await model.refresh()
        #expect(model.phase == .ready)
        #expect(model.status.untrackedChanges.map(\.path) == ["a.txt"])
        #expect(model.stats.added == 1)
        #expect(model.committableCount == 1)

        await model.stage(["a.txt"])
        #expect(model.status.stagedChanges.map(\.path) == ["a.txt"])
        model.commitMessage = "feat: 初始"
        await model.commit()
        #expect(model.lastError == nil)
        #expect(model.commitMessage.isEmpty)
        #expect(model.status.isClean)

        try "hello\nworld\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        await model.refresh()
        model.commitMessage = "feat: 全部"
        await model.commit()  // 没有暂存内容 → 自动 stage all
        #expect(model.status.isClean)
        #expect(try await model.repo?.log(limit: 5).count == 2)
    }

    @Test("失败操作写入 lastError 且不清空提交信息")
    func failureKeepsMessage() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let model = GitModel(projectPath: dir)
        await model.refresh()
        model.commitMessage = "无内容可提交"
        await model.commit()
        #expect(model.lastError != nil)
        #expect(model.commitMessage == "无内容可提交")
        #expect(model.busy == nil)
    }

    @Test("分支:新建并切换,绝对/相对路径换算")
    func branchesAndPaths() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "1\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let model = GitModel(projectPath: dir)
        await model.refresh()
        await model.stageAll()
        model.commitMessage = "init"
        await model.commit()
        await model.createBranch("feature/x")
        #expect(model.status.branch == "feature/x")
        #expect(model.branches.contains { $0.name == "feature/x" && $0.isCurrent })
        #expect(model.absolutePath("a.txt") == dir + "/a.txt")
        #expect(model.relativePath(dir + "/sub/b.txt") == "sub/b.txt")
        #expect(model.relativePath("/etc/hosts") == nil)
        await model.checkout("main")
        #expect(model.status.branch == "main")
    }
}
