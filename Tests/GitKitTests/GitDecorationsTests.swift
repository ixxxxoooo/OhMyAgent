// @author ixxxxoooo
import Foundation
import Testing
@testable import GitKit

/// 资源管理器 Git 装饰索引测试。
@Suite struct GitDecorationsTests {
    private func status(_ changes: [GitFileChange]) -> GitStatus {
        var status = GitStatus()
        status.changes = changes
        return status
    }

    @Test func fileKindsAndLetters() {
        let index = GitDecorationIndex(status: status([
            GitFileChange(path: "a.swift", unstaged: .modified),
            GitFileChange(path: "b.swift", staged: .added),
            GitFileChange(path: "c.swift", unstaged: .deleted),
            GitFileChange(path: "d.swift", isUntracked: true),
            GitFileChange(path: "e.swift", isConflicted: true),
        ]), base: "/p")
        #expect(index.kind(for: "/p/a.swift") == .modified)
        #expect(index.kind(for: "/p/b.swift") == .added)
        #expect(index.kind(for: "/p/c.swift") == .deleted)
        #expect(index.kind(for: "/p/d.swift")?.letter == "U")
        #expect(index.kind(for: "/p/e.swift")?.letter == "!")
        #expect(index.kind(for: "/p/none.swift") == nil)
    }

    @Test func directoriesBubbleUpMostSevere() {
        let index = GitDecorationIndex(status: status([
            GitFileChange(path: "Sources/Core/a.swift", isUntracked: true),
            GitFileChange(path: "Sources/Core/b.swift", unstaged: .modified),
            GitFileChange(path: "Sources/Other/c.swift", staged: .added),
        ]), base: "/p/")
        #expect(index.kind(for: "/p/Sources/Core") == .modified)
        #expect(index.kind(for: "/p/Sources/Other") == .added)
        // 上层目录取后代中最醒目的:modified(3) > added(2)
        #expect(index.kind(for: "/p/Sources") == .modified)
        // 仓库根自身不加装饰
        #expect(index.kind(for: "/p") == nil)
    }

    @Test func unstagedWinsOverStaged() {
        let change = GitFileChange(path: "x", staged: .added, unstaged: .modified)
        #expect(GitDecorationKind(change: change) == .modified)
    }

    @Test func cleanStatusIsEmpty() {
        #expect(GitDecorationIndex(status: GitStatus(), base: "/p").isEmpty)
    }
}
