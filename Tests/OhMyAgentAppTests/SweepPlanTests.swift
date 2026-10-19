// @author ixxxxoooo
// 流畅度基准的扫描计划测试:往返序列的长度、边界与汇总口径。

import Testing
@testable import OhMyAgentApp

@Suite("基准扫描计划")
struct SweepPlanTests {
    @Test("往返序列:长度 = 往返次数 × 单程步数 × 2,起止回到上限,范围不越界")
    func zigzag() {
        let values = SweepPlan.zigzag(low: 900, high: 1400, steps: 20, cycles: 3)
        #expect(values.count == 3 * 20 * 2)
        #expect(values.last == 1400)
        #expect(values.min() == 900)
        #expect(values.allSatisfy { $0 >= 900 && $0 <= 1400 })
    }

    @Test("非法参数返回空序列")
    func invalid() {
        #expect(SweepPlan.zigzag(low: 900, high: 1400, steps: 0, cycles: 3).isEmpty)
        #expect(SweepPlan.zigzag(low: 900, high: 1400, steps: 10, cycles: 0).isEmpty)
        #expect(SweepPlan.zigzag(low: 1400, high: 900, steps: 10, cycles: 1).isEmpty)
    }

    @Test("汇总:平均、最长与超过 33ms 的掉帧数")
    func summarize() {
        let r = SweepPlan.summarize([16, 17, 50, 16])
        #expect(r.frames == 5)
        #expect(r.maxMs == 50)
        #expect(r.hitches == 1)
        #expect(abs(r.avgMs - 24.75) < 0.001)
        #expect(SweepPlan.summarize([]).frames == 0)
    }
}
