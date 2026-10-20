// @author ixxxxoooo
// 分栏手柄:位移计算(屏幕坐标 y 向上)与命中区常量。

import Foundation
import Testing
@testable import OhMyAgentApp

@Suite("分栏手柄")
struct SplitHandleTests {
    @Test("竖线:向右拖为正、向左为负")
    func verticalTranslation() {
        let start = CGPoint(x: 100, y: 50)
        #expect(OMSplitHandle.translation(from: start, to: CGPoint(x: 130, y: 90), axis: .vertical) == 30)
        #expect(OMSplitHandle.translation(from: start, to: CGPoint(x: 70, y: 10), axis: .vertical) == -30)
    }

    @Test("横线:屏幕坐标 y 向上,向下拖为正")
    func horizontalTranslation() {
        let start = CGPoint(x: 100, y: 500)
        #expect(OMSplitHandle.translation(from: start, to: CGPoint(x: 100, y: 470), axis: .horizontal) == 30)
        #expect(OMSplitHandle.translation(from: start, to: CGPoint(x: 100, y: 530), axis: .horizontal) == -30)
    }

    @Test("命中区不小于 8pt 且大于发丝线")
    func hitArea() {
        #expect(OMSplitHandle.hitThickness >= 8)
        #expect(OMSplitHandle.hitThickness > OMSplitHandle.lineThickness)
        #expect(OMSplitHandle.activeThickness > OMSplitHandle.lineThickness)
    }
}
