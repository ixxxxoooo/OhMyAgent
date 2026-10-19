// @author ixxxxoooo
// 帧内合并:同一回合内多次请求只执行一次,下一回合可再次执行。

import Foundation
import Testing

@testable import ChatKit

@MainActor
@Suite("帧内合并动作")
struct FrameCoalescedActionTests {
    @Test("同一回合内的多次请求只执行一次,且用最后一个闭包")
    func coalescesWithinTurn() async {
        let action = FrameCoalescedAction()
        var log: [Int] = []
        action.schedule { log.append(1) }
        action.schedule { log.append(2) }
        action.schedule { log.append(3) }
        #expect(log.isEmpty)
        await Task.yield()
        await Task.yield()
        #expect(log == [3])
        #expect(action.executions == 1)
        #expect(action.coalesced == 2)
    }

    @Test("上一次执行之后的新请求会再次执行")
    func runsAgainAfterFlush() async {
        let action = FrameCoalescedAction()
        var count = 0
        action.schedule { count += 1 }
        await Task.yield()
        await Task.yield()
        action.schedule { count += 1 }
        await Task.yield()
        await Task.yield()
        #expect(count == 2)
    }
}
