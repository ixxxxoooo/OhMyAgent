// @author ixxxxoooo
// Git 状态徽标与轮询退避。

import Foundation
import Testing

@testable import GitKit

@Suite("Git 徽标与退避")
struct GitBadgeTests {
    @Test("干净且已同步时不显示圆点")
    func hidden() {
        let badge = GitBadge(status: GitStatus())
        #expect(!badge.isVisible)
        #expect(badge.tooltip == nil)
    }

    @Test("未提交、待推送、待拉取任一存在都显示,提示合并各项")
    func visible() {
        #expect(GitBadge(uncommitted: 3).isVisible)
        #expect(GitBadge(ahead: 1).isVisible)
        #expect(GitBadge(behind: 2).isOnlyBehind)
        let tip = GitBadge(uncommitted: 3, ahead: 2).tooltip ?? ""
        #expect(tip.contains("3") && tip.contains("2"))
    }

    @Test("状态变化时恢复基础间隔,不变时逐步放慢并封顶")
    func backoff() {
        #expect(PollBackoff.next(previous: 12, changed: true, duration: 0.1) == 3)
        var interval = 3.0
        for _ in 0..<10 { interval = PollBackoff.next(previous: interval, changed: false, duration: 0.1) }
        #expect(interval == 15)
    }

    @Test("单次刷新很慢时按耗时放慢")
    func slowRepo() {
        #expect(PollBackoff.next(previous: 3, changed: true, duration: 2) == 8)
    }
}
