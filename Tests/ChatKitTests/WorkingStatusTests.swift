// @author ygw
// 等待文案:动词稳定挑选、耗时格式化、整行文案。

import Testing
@testable import ChatKit

@Suite("等待文案")
struct WorkingStatusTests {
    @Test("动词按种子稳定挑选且支持负数种子")
    func verbSelection() {
        #expect(WorkingStatus.verb(seed: 3) == WorkingStatus.verb(seed: 3))
        #expect(WorkingStatus.verb(seed: 0) == WorkingStatus.verb(seed: WorkingStatus.verbs.count))
        #expect(!WorkingStatus.verb(seed: -7).isEmpty)
    }

    @Test("动画帧循环")
    func glyphLoop() {
        #expect(WorkingStatus.glyph(tick: 0) == WorkingStatus.glyph(tick: WorkingStatus.glyphFrames.count))
        #expect(!WorkingStatus.glyph(tick: -1).isEmpty)
    }

    @Test("耗时格式化")
    func elapsed() {
        #expect(WorkingStatus.elapsed(-5) == "0s")
        #expect(WorkingStatus.elapsed(12) == "12s")
        #expect(WorkingStatus.elapsed(65) == "1m 05s")
        #expect(WorkingStatus.elapsed(3720) == "1h 02m")
    }

    @Test("整行文案包含耗时与中断提示")
    func line() {
        let text = WorkingStatus.line(verb: "思考中", seconds: 12, canInterrupt: true)
        #expect(text.hasPrefix("思考中… (12s"))
        #expect(text.contains("Esc"))
        #expect(!WorkingStatus.line(verb: "思考中", seconds: 3, canInterrupt: false).contains("Esc"))
    }
}
