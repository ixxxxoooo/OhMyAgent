// @author ixxxxoooo
// 平滑滚轮模型测试:总位移守恒、与帧率无关、反向立即生效、上限。

import Testing
@testable import OhMyAgentApp

@Suite("平滑滚轮模型")
struct SmoothWheelModelTests {
    /// 跑完全部帧,返回累计像素。
    private func drain(_ model: inout SmoothWheelModel, fps: Double, tau: Double) -> (x: Int, y: Int, frames: Int) {
        var x = 0, y = 0, frames = 0
        while model.isActive && frames < 10_000 {
            let step = model.advance(dt: 1 / fps, tau: tau)
            x += step.x; y += step.y; frames += 1
        }
        return (x, y, frames)
    }

    @Test("总位移守恒:不论帧率,累计像素都等于输入")
    func conservesDistance() {
        for fps in [30.0, 60, 120, 240] {
            var model = SmoothWheelModel()
            model.add(dx: 0, dy: 108)
            let total = drain(&model, fps: fps, tau: 0.11)
            #expect(total.y == 108)
            #expect(total.x == 0)
        }
    }

    @Test("反向滚动立即生效:旧的剩余位移被丢弃")
    func reversalDropsRemaining() {
        var model = SmoothWheelModel()
        model.add(dx: 0, dy: 400)
        _ = model.advance(dt: 1 / 60, tau: 0.11)
        model.add(dx: 0, dy: -36)
        #expect(model.remainingY == -36)
    }

    @Test("同向连拨累加,且不超过上限")
    func accumulatesAndClamps() {
        var model = SmoothWheelModel()
        for _ in 0..<1_000 { model.add(dx: 0, dy: 36) }
        #expect(model.remainingY == SmoothWheelModel.maxRemaining)
    }

    @Test("tau 为 0 时一帧吐完;dt 为 0 时不动")
    func degenerateInputs() {
        var model = SmoothWheelModel()
        model.add(dx: 20, dy: 0)
        #expect(model.advance(dt: 0, tau: 0.11) == (0, 0))
        #expect(model.advance(dt: 1 / 60, tau: 0).x == 20)
        #expect(!model.isActive)
    }

    @Test("档位解析:未知值回退标准")
    func levelResolve() {
        #expect(SmoothWheelLevel.resolve("soft") == .soft)
        #expect(SmoothWheelLevel.resolve("???") == .standard)
    }
}
