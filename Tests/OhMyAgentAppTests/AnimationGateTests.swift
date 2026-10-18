// @author ixxxxoooo
// 循环动画门控:标签可见、应用可见、未减弱动态三者同时满足才允许持续动画。

import DesignSystem
import Testing

@Suite("循环动画门控")
struct AnimationGateTests {
    @Test("三个条件都满足才运行")
    func allConditions() {
        #expect(OMAnimationGate.shouldAnimate(tabActive: true, appVisible: true, reduceMotion: false))
    }

    @Test("后台标签不运行")
    func hiddenTab() {
        #expect(!OMAnimationGate.shouldAnimate(tabActive: false, appVisible: true, reduceMotion: false))
    }

    @Test("窗口被遮挡或最小化不运行")
    func hiddenApp() {
        #expect(!OMAnimationGate.shouldAnimate(tabActive: true, appVisible: false, reduceMotion: false))
    }

    @Test("减弱动态效果不运行")
    func reducedMotion() {
        #expect(!OMAnimationGate.shouldAnimate(tabActive: true, appVisible: true, reduceMotion: true))
    }
}
