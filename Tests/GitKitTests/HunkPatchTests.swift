// @author ixxxxoooo
// 块级暂存/取消暂存/放弃:用真实 git 在临时仓库验证补丁生成与 `git apply`。

import DiffKit
import Foundation
import Testing

@testable import GitKit

@Suite("块级补丁", .serialized)
struct HunkPatchTests {
    /// 建仓库并提交一个 20 行文件 a.txt(行内容 L1…L20)。
    private func makeRepo(trailingNewline: Bool = true) async throws -> (GitRepository, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oma-hunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: realpath(dir.path, nil).map { String(cString: $0) } ?? dir.path)
        _ = try await GitProcess.run(["init", "-b", "main"], in: real)
        for (k, v) in [("user.name", "Tester"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] {
            _ = try await GitProcess.run(["config", k, v], in: real)
        }
        let body = (1...20).map { "L\($0)" }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(to: real.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(["add", "."], in: real)
        _ = try await GitProcess.run(["commit", "-m", "init"], in: real)
        return (GitRepository(root: real), real)
    }

    /// 同时改第 2 行与第 19 行,得到两个独立的块。
    private func editTwoPlaces(_ root: URL, trailingNewline: Bool = true) throws {
        var lines = (1...20).map { "L\($0)" }
        lines[1] = "CHANGED-2"
        lines[18] = "CHANGED-19"
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    @Test("暂存第一块:暂存区只含第一处改动")
    func stageOneHunk() async throws {
        let (repo, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try editTwoPlaces(root)
        let diff = try #require(try await repo.fileDiff(path: "a.txt", scope: .unstaged))
        #expect(diff.hunks.count == 2)
        try await repo.applyHunk(.stage, path: "a.txt", diff: diff, hunkID: diff.hunks[0].id)
        let staged = try #require(try await repo.fileDiff(path: "a.txt", scope: .staged))
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks[0].lines.contains { $0.text == "CHANGED-2" })
        let rest = try #require(try await repo.fileDiff(path: "a.txt", scope: .unstaged))
        #expect(rest.hunks.count == 1)
        #expect(rest.hunks[0].lines.contains { $0.text == "CHANGED-19" })
    }

    @Test("取消暂存某块后回到未暂存")
    func unstageHunk() async throws {
        let (repo, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try editTwoPlaces(root)
        try await repo.stage(["a.txt"])
        let staged = try #require(try await repo.fileDiff(path: "a.txt", scope: .staged))
        try await repo.applyHunk(.unstage, path: "a.txt", diff: staged, hunkID: staged.hunks[1].id)
        let after = try #require(try await repo.fileDiff(path: "a.txt", scope: .staged))
        #expect(after.hunks.count == 1)
        #expect(after.hunks[0].lines.contains { $0.text == "CHANGED-2" })
    }

    @Test("放弃某块只还原该块,文件其余修改保留")
    func discardHunk() async throws {
        let (repo, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try editTwoPlaces(root)
        let diff = try #require(try await repo.fileDiff(path: "a.txt", scope: .unstaged))
        try await repo.applyHunk(.discard, path: "a.txt", diff: diff, hunkID: diff.hunks[1].id)
        let text = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(text.contains("CHANGED-2"))
        #expect(!text.contains("CHANGED-19"))
        #expect(text.contains("L19"))
    }

    @Test("文件末尾没有换行时也能正确暂存")
    func noTrailingNewline() async throws {
        let (repo, root) = try await makeRepo(trailingNewline: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try editTwoPlaces(root, trailingNewline: false)
        let diff = try #require(try await repo.fileDiff(path: "a.txt", scope: .unstaged))
        try await repo.applyHunk(.stage, path: "a.txt", diff: diff, hunkID: diff.hunks[1].id)
        let staged = try #require(try await repo.fileDiff(path: "a.txt", scope: .staged))
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks[0].lines.contains { $0.text == "CHANGED-19" })
    }

    @Test("块已不存在时抛出参数错误")
    func missingHunk() async throws {
        let (repo, root) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try editTwoPlaces(root)
        let diff = try #require(try await repo.fileDiff(path: "a.txt", scope: .unstaged))
        await #expect(throws: GitError.self) { try await repo.applyHunk(.stage, path: "a.txt", diff: diff, hunkID: 999) }
    }
}
