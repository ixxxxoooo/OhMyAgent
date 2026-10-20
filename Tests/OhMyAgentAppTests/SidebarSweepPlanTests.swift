// @author ixxxxoooo
// 项目栏基准的纯计算部分测试。

import Testing
@testable import OhMyAgentApp

@Suite("项目栏基准计划")
struct SidebarSweepPlanTests {
    @Test("环境变量解析:all 取全部、逗号分隔按固定顺序、非法忽略")
    func kinds() {
        #expect(SidebarSweepPlan.kinds(from: nil).isEmpty)
        #expect(SidebarSweepPlan.kinds(from: "").isEmpty)
        #expect(SidebarSweepPlan.kinds(from: "x,y").isEmpty)
        #expect(SidebarSweepPlan.kinds(from: "all") == SidebarSweepPlan.Kind.allCases)
        #expect(SidebarSweepPlan.kinds(from: "status, scroll") == [.scroll, .status])
        #expect(SidebarSweepPlan.kinds(from: "idle") == [.idle])
    }

    @Test("主线程忙碌时间汇总:总和除以帧数,最长取单次最大")
    func busy() {
        let summary = SidebarSweepPlan.summarizeBusy([2, 4, 6], frames: 3)
        #expect(summary.perFrameMs == 4)
        #expect(summary.maxMs == 6)
        #expect(SidebarSweepPlan.summarizeBusy([], frames: 3).perFrameMs == 0)
        #expect(SidebarSweepPlan.summarizeBusy([1], frames: 0).maxMs == 0)
    }

    @Test("悬停路径落在给定范围内且往返")
    func hoverPath() {
        let path = SidebarSweepPlan.hoverPath(top: 900, bottom: 100, steps: 10, cycles: 2)
        #expect(path.count == 40)
        #expect(path.allSatisfy { $0 >= 100 && $0 <= 900 })
    }
}
