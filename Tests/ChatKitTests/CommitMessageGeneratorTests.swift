// @author ixxxxoooo
// 提交说明生成器:材料解析、补丁精简、提示词、结果清洗与启发式兜底。

import Foundation
import Testing
@testable import ChatKit

@Suite("提交说明生成")
struct CommitMessageGeneratorTests {
    private let patch = """
    diff --git a/Sources/GitKit/Sync.swift b/Sources/GitKit/Sync.swift
    new file mode 100644
    --- /dev/null
    +++ b/Sources/GitKit/Sync.swift
    @@ -0,0 +1,4 @@
    +public struct SyncPlan {
    +    public func run() {}
    +}
    diff --git a/Package.resolved b/Package.resolved
    --- a/Package.resolved
    +++ b/Package.resolved
    @@ -1 +1 @@
    -old
    +new
    """

    @Test("合并 name-status 与 numstat 得到文件清单")
    func parseFiles() {
        let files = CommitMessageGenerator.parseFiles(
            nameStatus: "M\tSources/A.swift\nA\tSources/B.swift\nR100\told.swift\tnew.swift\n",
            numstat: "3\t1\tSources/A.swift\n10\t0\tSources/B.swift\n0\t0\tnew.swift\n",
            untracked: ["Notes.md", "Sources/B.swift"])
        #expect(files.map(\.path) == ["Sources/A.swift", "Sources/B.swift", "new.swift", "Notes.md"])
        #expect(files[0].added == 3 && files[0].removed == 1)
        #expect(files[2].status == "R")
        #expect(files[3].status == "A")
    }

    @Test("精简补丁:去掉锁文件并标注省略")
    func condenseDropsNoise() {
        let out = CommitMessageGenerator.condensePatch(patch)
        #expect(out.contains("SyncPlan"))
        #expect(!out.contains("-old"))
        #expect(out.contains("Package.resolved"))
    }

    @Test("精简补丁:单文件超长被截断,总量受预算限制")
    func condenseTruncates() {
        let big = "diff --git a/Sources/X.swift b/Sources/X.swift\n" + String(repeating: "+let value = 1\n", count: 2000)
        let out = CommitMessageGenerator.condensePatch(big, budget: 5000, perFile: 800)
        #expect(out.count < 1200)
        #expect(out.contains("已截断"))
    }

    @Test("提示词带上最近提交风格与语言要求")
    func promptContainsStyle() {
        let context = CommitContext(branch: "main", files: [CommitFileChange(path: "Sources/GitKit/Sync.swift", status: "A", added: 4)], patch: patch,
                                    recentSubjects: ["feat: 新增会话标题", "fix: 修复滚动"])
        let text = CommitMessageGenerator.prompt(for: context)
        #expect(text.contains("Conventional Commits"))
        #expect(text.contains("中文"))
        #expect(text.contains("- feat: 新增会话标题"))
        #expect(text.contains("A Sources/GitKit/Sync.swift"))
        #expect(text.contains("当前分支:main"))
    }

    @Test("英文仓库提示英文输出;非规范提交不强制 type")
    func promptEnglish() {
        let context = CommitContext(files: [CommitFileChange(path: "a.txt", status: "M")], patch: "", recentSubjects: ["Update readme", "Add logo", "Tidy up"])
        let text = CommitMessageGenerator.prompt(for: context)
        #expect(text.contains("英文"))
        #expect(text.contains("模仿"))
    }

    @Test("清洗模型输出:围栏、引号、前缀、句号")
    func cleanOutput() {
        let raw = "```\n提交说明:feat(git): 新增同步按钮。\n\n\n- 提交后变为同步\n```"
        #expect(CommitMessageGenerator.clean(raw) == "feat(git): 新增同步按钮\n\n- 提交后变为同步")
        #expect(CommitMessageGenerator.clean("\"fix: 修复崩溃\"") == "fix: 修复崩溃")
        #expect(CommitMessageGenerator.clean("  \n ") == nil)
    }

    @Test("启发式:新增源码判为 feat,作用域取模块,描述用新增类型名")
    func heuristicFeature() {
        let context = CommitContext(files: [CommitFileChange(path: "Sources/GitKit/Sync.swift", status: "A", added: 4)], patch: patch,
                                    recentSubjects: ["feat: 新增会话标题"])
        let message = CommitMessageGenerator.heuristic(for: context)
        #expect(message == "feat(GitKit): 新增 SyncPlan、run")
    }

    @Test("启发式:纯测试与纯文档")
    func heuristicTypes() {
        let tests = CommitContext(files: [CommitFileChange(path: "Tests/ChatKitTests/FooTests.swift", status: "M", added: 5, removed: 1)], patch: "", recentSubjects: ["fix: x"])
        #expect(CommitMessageGenerator.heuristic(for: tests).hasPrefix("test(ChatKitTests)"))
        let docs = CommitContext(files: [CommitFileChange(path: "README.md", status: "M", added: 2, removed: 1)], patch: "", recentSubjects: ["docs: 更新"])
        #expect(CommitMessageGenerator.heuristic(for: docs).hasPrefix("docs:"))
    }

    @Test("启发式:多文件附带要点,英文仓库用英文")
    func heuristicMultiFile() {
        let files = (1...8).map { CommitFileChange(path: "Sources/App/File\($0).swift", status: "M", added: 3, removed: 2) }
        let message = CommitMessageGenerator.heuristic(for: CommitContext(files: files, patch: "", recentSubjects: ["Update thing", "Add another"]))
        let lines = message.components(separatedBy: "\n")
        #expect(!(lines.first ?? "").contains("更新"))
        #expect(message.contains("\n\n- update File1.swift (+3 −2)"))
        #expect(message.contains("and 2 more files"))
    }

    @Test("请求体包含模型别名与提示词")
    func requestBody() throws {
        let context = CommitContext(files: [CommitFileChange(path: "a.swift", status: "M")], patch: "diff --git a/a.swift b/a.swift\n+x")
        let data = try #require(CommitMessageGenerator.requestBody(model: "oma-small", context: context))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "oma-small")
        #expect(object["stream"] as? Bool == false)
    }
}
