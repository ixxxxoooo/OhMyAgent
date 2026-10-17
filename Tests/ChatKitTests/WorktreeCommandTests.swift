// @author ixxxxoooo
// 工作树斜杠命令的解析。

import Testing
@testable import ChatKit

@Suite("工作树命令解析")
struct WorktreeCommandTests {
    @Test("基本命令")
    func basics() {
        #expect(LocalCommands.parse("/worktree") == .worktree(""))
        #expect(LocalCommands.parse("/worktree 修复登录") == .worktree("修复登录"))
        #expect(LocalCommands.parse("/apply-worktree") == .applyWorktree)
        #expect(LocalCommands.parse("/delete-worktree") == .deleteWorktree)
        #expect(LocalCommands.names.isSuperset(of: ["worktree", "apply-worktree", "delete-worktree", "best-of-n"]))
    }

    @Test("best-of-n:模型去重、限制个数、需要任务")
    func bestOfN() {
        let ok = LocalCommands.parseBestOfN("sonnet,opus,SONNET,haiku,a,b 重构登录模块")
        #expect(ok?.models == ["sonnet", "opus", "haiku", "a"])
        #expect(ok?.task == "重构登录模块")
        #expect(LocalCommands.parseBestOfN("sonnet") == nil)
        #expect(LocalCommands.parseBestOfN(",, 任务") == nil)
        #expect(LocalCommands.parse("/best-of-n opus,sonnet 写测试") == .bestOfN(models: ["opus", "sonnet"], task: "写测试"))
        #expect(LocalCommands.parse("/best-of-n") == .bestOfN(models: [], task: ""))
    }
}
