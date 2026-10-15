// @author ygw
// Git Graph 泳道布局测试。

import Foundation
import Testing

@testable import GitKit

private func commit(_ name: String, parents: [String]) -> GitCommit {
    GitCommit(hash: name, parents: parents, author: "A", email: "a@x", date: Date(), subject: name, refs: [])
}

@Suite("Git Graph")
struct GitGraphTests {
    @Test("线性历史:全部在第 0 列,颜色一致")
    func linear() {
        let rows = GitGraph.layout([commit("c", parents: ["b"]), commit("b", parents: ["a"]), commit("a", parents: [])])
        #expect(rows.map(\.column) == [0, 0, 0])
        #expect(Set(rows.map(\.color)).count == 1)
        #expect(rows[0].incoming.isEmpty && rows[1].incoming == [0])
        #expect(rows[2].outgoing.isEmpty && rows[2].bottom.isEmpty)
    }

    @Test("分叉合并:合并提交有两条出线,支线汇回主线泳道")
    func mergeAndBranch() {
        // m(合并 b、c) ← b ← a;c ← a
        let rows = GitGraph.layout([
            commit("m", parents: ["b", "c"]),
            commit("b", parents: ["a"]),
            commit("c", parents: ["a"]),
            commit("a", parents: []),
        ])
        #expect(rows[0].column == 0 && rows[0].outgoing.count == 2)
        #expect(rows[0].bottom.compactMap { $0 }.count == 2)
        #expect(rows[1].column == 0)          // b 在主线
        #expect(rows[2].column == 1)          // c 在第二条泳道
        #expect(rows[2].color != rows[1].color)
        // c 的父提交 a 已在主线泳道等待:c 直接连向第 0 列,第 1 列在 c 处结束
        #expect(rows[2].outgoing == [0])
        #expect(rows[2].bottom.compactMap { $0 }.count == 1)
        #expect(rows[3].incoming == [0] && rows[3].column == 0)
        #expect(rows[3].bottom.isEmpty)
    }

    @Test("多个分支末端各占一列")
    func multipleTips() {
        let rows = GitGraph.layout([
            commit("x", parents: ["base"]),
            commit("y", parents: ["base"]),
            commit("base", parents: []),
        ])
        #expect(rows[0].column == 0 && rows[1].column == 1)
        #expect(rows[1].outgoing == [0] && rows[1].laneCount == 2)  // y 连向 base 所在的第 0 列
        #expect(rows[2].incoming == [0] && rows[2].laneCount == 1)
    }

    @Test("空输入与大输入性能")
    func edge() {
        #expect(GitGraph.layout([]).isEmpty)
        let many = (0..<5000).map { commit("c\($0)", parents: ["c\($0 + 1)"]) }
        #expect(GitGraph.layout(many).count == 5000)
    }
}
