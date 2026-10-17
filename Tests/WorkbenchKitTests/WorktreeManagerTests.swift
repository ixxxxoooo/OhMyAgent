// @author ixxxxoooo
// 工作树管理的纯逻辑与真实 Git 流程测试。

import Foundation
import GitKit
import Testing
@testable import WorkbenchKit

@Suite("工作树管理")
struct WorktreeManagerTests {
    @Test("slug 只保留 ASCII 字母数字,全中文回退 task")
    func slug() {
        #expect(WorktreeManager.slug("Fix Login Bug!") == "fix-login-bug")
        #expect(WorktreeManager.slug("修复登录") == "task")
        #expect(WorktreeManager.slug("  --a__b--  ") == "a-b")
        #expect(WorktreeManager.slug(String(repeating: "x", count: 80)).count == 32)
    }

    @Test("重名时追加序号")
    func uniqueName() {
        #expect(WorktreeManager.makeName(title: "task", existing: []) == "task")
        #expect(WorktreeManager.makeName(title: "task", existing: ["task", "task-2"]) == "task-3")
    }

    @Test("目标目录位于根目录下且按仓库哈希分组")
    func destination() {
        let path = WorktreeManager.destination(repoRoot: "/a/b", name: "x", home: "/h")
        #expect(path == "/h/.ohmyagent/worktrees/\(WorktreeManager.repoHash("/a/b"))/x")
        #expect(WorktreeManager.isManaged(path: path, home: "/h"))
        #expect(!WorktreeManager.isManaged(path: "/a/b", home: "/h"))
        #expect(WorktreeManager.repoHash("/a/b") != WorktreeManager.repoHash("/a/c"))
        #expect(WorktreeManager.branchName(for: "x") == "oma/x")
    }

    @Test("清理从最旧的干净工作树开始,不超限不清理")
    func cleanup() {
        let now = Date()
        let items = (0..<5).map { ManagedWorktree(path: "/w/\($0)", branch: "oma/\($0)", modified: now.addingTimeInterval(Double($0)), isDirty: $0 == 0) }
        #expect(WorktreeManager.cleanupCandidates(items, maxCount: 5).isEmpty)
        let doomed = WorktreeManager.cleanupCandidates(items, maxCount: 3)
        #expect(doomed.map(\.path) == ["/w/1", "/w/2"])
        #expect(WorktreeManager.cleanupCandidates(items, maxCount: 0).count == 4)
    }

    @Test("读取初始化脚本:oma 配置优先,unix 键优先,脚本路径存在时包一层 sh")
    func loadSetup() throws {
        let root = NSTemporaryDirectory() + "oma-wt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.oma", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.cursor", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(WorktreeManager.loadSetup(repoRoot: root) == nil)
        try Data(#"{"setup-worktree":["echo cursor"]}"#.utf8).write(to: URL(fileURLWithPath: root + "/.cursor/worktrees.json"))
        #expect(WorktreeManager.loadSetup(repoRoot: root)?.commands == ["echo cursor"])
        try Data(#"{"setup-worktree":["a"],"setup-worktree-unix":["b","c"]}"#.utf8).write(to: URL(fileURLWithPath: root + "/.oma/worktrees.json"))
        #expect(WorktreeManager.loadSetup(repoRoot: root)?.commands == ["b", "c"])
        try Data("echo hi".utf8).write(to: URL(fileURLWithPath: root + "/setup.sh"))
        try Data(#"{"setup-worktree":"setup.sh"}"#.utf8).write(to: URL(fileURLWithPath: root + "/.oma/worktrees.json"))
        #expect(WorktreeManager.loadSetup(repoRoot: root)?.commands.first?.hasPrefix("/bin/sh '") == true)
    }

    @Test("初始化脚本在工作树目录运行并注入 ROOT_WORKTREE_PATH,失败即停止")
    func runSetup() async throws {
        let dir = NSTemporaryDirectory() + "oma-wt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ok = await WorktreeManager.runSetup(WorktreeSetup(commands: ["echo $ROOT_WORKTREE_PATH > out.txt"]), worktreePath: dir, rootPath: "/root/x")
        #expect(ok)
        let text = try String(contentsOfFile: dir + "/out.txt", encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "/root/x")
        let failed = await WorktreeManager.runSetup(WorktreeSetup(commands: ["exit 3", "touch never.txt"]), worktreePath: dir, rootPath: "/r")
        #expect(!failed)
        #expect(!FileManager.default.fileExists(atPath: dir + "/never.txt"))
    }

    @Test("创建 → 在工作树提交 → 应用 → 删除 的完整流程;主检出脏时拒绝应用")
    func lifecycle() async throws {
        let home = NSTemporaryDirectory() + "oma-wt-home-\(UUID().uuidString)"
        let repoDir = NSTemporaryDirectory() + "oma-wt-repo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home); try? FileManager.default.removeItem(atPath: repoDir) }
        let repo = try await GitRepository.initialize(at: repoDir)
        try Data("a\n".utf8).write(to: URL(fileURLWithPath: repoDir + "/a.txt"))
        try await repo.stageAll()
        _ = try await repo.commit(message: "init")

        let created = try await WorktreeManager.create(in: repo, title: "Add Feature", home: home)
        #expect(created.branch == "oma/add-feature")
        #expect(FileManager.default.fileExists(atPath: created.path + "/a.txt"))
        let managed = await WorktreeManager.listManaged(in: repo, home: home)
        #expect(managed.count == 1)

        try Data("b\n".utf8).write(to: URL(fileURLWithPath: created.path + "/b.txt"))
        // 主检出脏 → 拒绝
        try Data("dirty\n".utf8).write(to: URL(fileURLWithPath: repoDir + "/dirty.txt"))
        await #expect(throws: WorktreeError.originDirty) {
            try await WorktreeManager.apply(origin: repo, worktreePath: created.path, branch: created.branch)
        }
        try FileManager.default.removeItem(atPath: repoDir + "/dirty.txt")
        try await WorktreeManager.apply(origin: repo, worktreePath: created.path, branch: created.branch)
        #expect(FileManager.default.fileExists(atPath: repoDir + "/b.txt"))

        try await WorktreeManager.remove(origin: repo, worktreePath: created.path, branch: created.branch, deleteBranch: true)
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(await WorktreeManager.listManaged(in: repo, home: home).isEmpty)
    }
}
