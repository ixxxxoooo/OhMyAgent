// @author ixxxxoooo
// 规则加载顺序测试:先后次序、规则目录合并、AGENTS.md 不参与。

import Foundation
import Testing

@testable import ClaudeConfigKit

@Suite("规则加载顺序")
struct MemoryLoadOrderTests {
    private func file(_ kind: MemoryFile.Kind, _ name: String, exists: Bool = true) -> MemoryFile {
        MemoryFile(kind: kind, title: name, url: URL(fileURLWithPath: "/tmp/\(name)"), exists: exists, pathFilters: [], isLoadedByDefault: true)
    }

    /// 乱序输入也按「用户 → 用户规则 → 项目 → 项目规则 → 本地」排列,规则目录合并成一步,AGENTS.md 被排除。
    @Test("按加载先后排序并合并规则")
    func ordering() {
        let files = [
            file(.local, "l"), file(.projectRule, "r2"), file(.agentsMD, "a"), file(.user, "u"),
            file(.projectRule, "r1"), file(.project, "p"), file(.projectInClaudeDir, "pc", exists: false), file(.userRule, "ur"),
        ]
        let steps = MemoryStore.loadOrder(of: files)
        #expect(steps.map(\.id) == ["user", "userRule", "project", "projectRule", "local"])
        #expect(steps[2].files.count == 2)
        #expect(steps[3].files.count == 2)
        #expect(!steps.flatMap(\.files).contains { $0.kind == .agentsMD })
    }

    /// 没有任何规则文件时不出现规则步骤;文件都不存在的步骤标记为未创建。
    @Test("缺失位置")
    func missing() {
        let steps = MemoryStore.loadOrder(of: [file(.user, "u", exists: false)])
        #expect(steps.map(\.id) == ["user"])
        #expect(!steps[0].exists)
    }
}
