// @author ixxxxoooo
// 托盘:图标必须是 template(不再出现黑色)、状态点规格与颜色取主题强调色。

import AppKit
import ChatKit
import DesignSystem
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("托盘图标与状态点")
struct StatusItemTests {
    @Test("图标是 template,由系统按菜单栏明暗着色(完整标记与仅圆环两种)")
    func iconIsTemplate() {
        #expect(StatusItemController.templateIcon().isTemplate)
        #expect(StatusItemController.templateIcon(withDot: false).isTemplate)
    }

    @Test("状态点对准标记运行点:位于圆环半径上、右上 40°,与运行点同大")
    func dotSitsOnMark() {
        let offset = StatusItemController.markDotOffset
        #expect(abs(hypot(offset.x, offset.y) - 6.2) < 0.001)
        #expect(offset.x > 0 && offset.y > 0)
        #expect(abs(atan2(offset.y, offset.x) * 180 / .pi - 40) < 0.001)
        #expect(StatusItemController.markDotRadius == 2.1)
    }

    @Test("状态点规格:运行实心呼吸、待处理空心环呼吸、未读静止、无状态不显示")
    func dotSpecs() {
        #expect(TrayDotSpec.make(indicator: .none, reduceMotion: false) == nil)
        #expect(TrayDotSpec.make(indicator: .running, reduceMotion: false) == TrayDotSpec(ring: false, breathPeriod: 0.6))
        #expect(TrayDotSpec.make(indicator: .needsInput, reduceMotion: false)?.ring == true)
        #expect(TrayDotSpec.make(indicator: .unread, reduceMotion: false)?.breathPeriod == nil)
    }

    @Test("减弱动态效果时不呼吸")
    func reduceMotionStops() {
        #expect(TrayDotSpec.make(indicator: .running, reduceMotion: true)?.breathPeriod == nil)
        #expect(TrayDotSpec.make(indicator: .needsInput, reduceMotion: true)?.breathPeriod == nil)
    }

    @Test("状态点颜色取主题强调色")
    func dotColorFollowsAccent() {
        let expected = NSColor(OMColors.accent).usingColorSpace(.sRGB)
        for indicator in [TrayIndicator.running, .needsInput, .unread] {
            #expect(StatusItemController.dotColor(indicator)?.usingColorSpace(.sRGB) == expected)
        }
        #expect(StatusItemController.dotColor(.none) == nil)
    }
}
