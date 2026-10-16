// @author ixxxxoooo
// git 输出解析器测试(固定样本,不依赖真实仓库)。

import Foundation
import Testing

@testable import GitKit

@Suite("Git 解析器")
struct GitParsersTests {
    private func nul(_ parts: [String]) -> Data {
        Data((parts.joined(separator: "\u{0}") + "\u{0}").utf8)
    }

    @Test("status:分支头、领先落后与各类变化")
    func status() {
        let data = nul([
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb Sources/a.swift",
            "1 .M N... 100644 100644 100644 aaa bbb b.txt",
            "1 AM N... 000000 100644 100644 000 bbb new file.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 renamed.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? untracked dir/x.md",
        ])
        let status = GitParsers.parseStatus(data)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.headOID?.count == 40)
        #expect(status.changes.count == 6)
        #expect(status.stagedChanges.map(\.path).contains("Sources/a.swift"))
        #expect(status.unstagedChanges.map(\.path) == ["b.txt", "new file.txt"])
        let renamed = status.changes.first { $0.path == "renamed.txt" }
        #expect(renamed?.staged == .renamed && renamed?.originalPath == "old name.txt")
        #expect(status.conflicts.map(\.path) == ["conflict.txt"])
        #expect(status.untrackedChanges.map(\.path) == ["untracked dir/x.md"])
        #expect(!status.isClean)
    }

    @Test("status:初始仓库与游离 HEAD")
    func statusEdge() {
        let initial = GitParsers.parseStatus(nul(["# branch.oid (initial)", "# branch.head main"]))
        #expect(initial.headOID == nil && initial.branch == "main" && initial.isClean)
        let detached = GitParsers.parseStatus(nul(["# branch.oid abc", "# branch.head (detached)"]))
        #expect(detached.isDetached)
    }

    @Test("numstat 求和,二进制计 0")
    func numstat() {
        let stats = GitParsers.parseNumstat("3\t1\ta.swift\n10\t0\tb.swift\n-\t-\timg.png\n")
        #expect(stats == GitLineStats(added: 13, removed: 1))
    }

    @Test("log 解析:引用、父提交与主题")
    func log() {
        let text = "\(String(repeating: "a", count: 40))\u{1f}\(String(repeating: "b", count: 40)) \(String(repeating: "c", count: 40))\u{1f}张三\u{1f}z@x.com\u{1f}1700000000\u{1f}HEAD -> main, origin/main, tag: v1\u{1f}合并 | 分支\u{1e}\n"
            + "\(String(repeating: "b", count: 40))\u{1f}\u{1f}李四\u{1f}l@x.com\u{1f}1690000000\u{1f}\u{1f}init\u{1e}"
        let commits = GitParsers.parseLog(text)
        #expect(commits.count == 2)
        #expect(commits[0].isMerge && commits[0].parents.count == 2)
        #expect(commits[0].refs == ["HEAD -> main", "origin/main", "tag: v1"])
        #expect(commits[0].subject == "合并 | 分支")
        #expect(commits[0].shortHash == "aaaaaaa")
        #expect(commits[1].parents.isEmpty && commits[1].refs.isEmpty)
        #expect(commits[1].date == Date(timeIntervalSince1970: 1690000000))
    }

    @Test("blame porcelain:元数据只在首次出现时给出")
    func blame() {
        let h1 = String(repeating: "1", count: 40), h2 = String(repeating: "0", count: 40)
        let text = """
        \(h1) 1 1 2
        author 张三
        author-time 1700000000
        summary 初始提交
        filename a.txt
        \tline one
        \(h1) 2 2
        \tline two
        \(h2) 3 3 1
        author Not Committed Yet
        author-time 1700000100
        summary Version of a.txt from a.txt
        filename a.txt
        \tline three
        """
        let lines = GitParsers.parseBlame(text)
        #expect(lines.count == 3)
        #expect(lines[1].author == "张三" && lines[1].summary == "初始提交" && lines[1].text == "line two")
        #expect(lines[2].isUncommitted && !lines[0].isUncommitted)
        #expect(lines.map(\.lineNumber) == [1, 2, 3])
    }

    @Test("分支与 stash 解析")
    func branchesAndStashes() {
        let text = "refs/heads/main\u{1f}main\u{1f}*\u{1f}origin/main\u{1f}abc\u{1f}修复\n"
            + "refs/heads/dev\u{1f}dev\u{1f} \u{1f}\u{1f}def\u{1f}wip\n"
            + "refs/remotes/origin/main\u{1f}origin/main\u{1f} \u{1f}\u{1f}abc\u{1f}修复\n"
            + "refs/remotes/origin/HEAD\u{1f}origin\u{1f} \u{1f}\u{1f}abc\u{1f}修复\n"
        let branches = GitParsers.parseBranches(text)
        #expect(branches.count == 3)
        #expect(branches[0].isCurrent && branches[0].upstream == "origin/main")
        #expect(branches[2].isRemote)
        let stashes = GitParsers.parseStashes("stash@{0}\u{1f}On main: a\nstash@{1}\u{1f}WIP on dev: b\n")
        #expect(stashes.map(\.index) == [0, 1])
        #expect(stashes[1].message == "WIP on dev: b")
    }

    @Test("name-status 解析含重命名")
    func nameStatus() {
        let files = GitParsers.parseNameStatus(nul(["M", "a.txt", "R100", "old.txt", "new.txt", "D", "gone.txt", "A", "n.txt"]))
        #expect(files.map(\.path) == ["a.txt", "new.txt", "gone.txt", "n.txt"])
        #expect(files[1].originalPath == "old.txt" && files[1].staged == .renamed)
        #expect(files[2].staged == .deleted)
    }
}
