// @author ixxxxoooo
// 事件屏障与合并器排空测试:回合结束时确保尾部通知先于「结束」被应用。

import ACPKit
import Foundation
import Testing

@testable import ChatKit

@Suite("事件屏障与排空")
struct EventBarrierTests {
    @Test("屏障先登记后等待、先等待后登记都能到达;未登记时超时返回 false")
    func barrier() async {
        let barrier = EventBarrier()
        barrier.signal("a")
        #expect(await barrier.wait("a", timeout: .milliseconds(200)))
        // 同一标识只消费一次
        #expect(await barrier.wait("a", timeout: .milliseconds(30)) == false)
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            barrier.signal("b")
        }
        #expect(await barrier.wait("b", timeout: .seconds(1)))
        #expect(await barrier.wait("never", timeout: .milliseconds(30)) == false)
    }

    @Test("drain 在批次全部应用后返回,否则超时")
    func drain() async {
        let coalescer = EventCoalescer(interval: .seconds(10))
        coalescer.push(.stderr("x"))
        coalescer.push(.stderr("y"))
        // 消费者:收到批次后标记已应用
        let consumer = Task {
            for await batch in coalescer.batches { coalescer.markApplied(batch.count) }
        }
        #expect(await coalescer.drain(timeout: .seconds(1)))
        consumer.cancel()
        // 无人消费时超时
        let idle = EventCoalescer(interval: .seconds(10))
        idle.push(.stderr("z"))
        #expect(await idle.drain(timeout: .milliseconds(30)) == false)
    }
}
