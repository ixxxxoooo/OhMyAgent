// @author ixxxxoooo
// 终端输出缓冲测试:小块直喂、预算分批、顺序与完整性、清空。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("终端输出缓冲")
struct TerminalOutputBufferTests {
    @Test("缓冲为空且块很小时可直接喂入;有积压或块很大时不可")
    func directFeed() {
        var buffer = TerminalOutputBuffer()
        #expect(buffer.canFeedDirectly(count: 100))
        #expect(!buffer.canFeedDirectly(count: TerminalOutputBuffer.directLimit + 1))
        buffer.append([1, 2, 3][...])
        #expect(!buffer.canFeedDirectly(count: 1))
    }

    @Test("按预算分批取出,拼起来与输入完全一致")
    func batchesPreserveBytes() {
        var buffer = TerminalOutputBuffer()
        let input = (0..<1000).map { UInt8($0 % 251) }
        buffer.append(input[...])
        var output: [UInt8] = []
        var frames = 0
        while !buffer.isEmpty {
            let frame = buffer.takeFrame(budget: 300)
            #expect(frame.count <= 300)
            output += frame
            frames += 1
        }
        #expect(output == input)
        #expect(frames == 4)
        #expect(buffer.takeFrame().isEmpty)
    }

    @Test("多次追加保持先后顺序;清空后为空")
    func appendOrderAndClear() {
        var buffer = TerminalOutputBuffer()
        buffer.append([1, 2][...])
        buffer.append([3][...])
        #expect(Array(buffer.takeFrame(budget: 2)) == [1, 2])
        buffer.append([4][...])
        #expect(buffer.pendingCount == 2)
        buffer.removeAll()
        #expect(buffer.isEmpty)
    }

    @Test("非法预算按 1 处理,保证前进")
    func invalidBudget() {
        var buffer = TerminalOutputBuffer()
        buffer.append([7, 8][...])
        #expect(buffer.takeFrame(budget: 0).count == 1)
        #expect(buffer.takeFrame(budget: -5).count == 1)
        #expect(buffer.isEmpty)
    }

    @Test("大量数据跨过压缩阈值后仍然完整")
    func compaction() {
        var buffer = TerminalOutputBuffer()
        let input = [UInt8](repeating: 9, count: 3 * 1 << 20)
        buffer.append(input[...])
        var total = 0
        while !buffer.isEmpty { total += buffer.takeFrame(budget: 700_000).count }
        #expect(total == input.count)
    }
}
