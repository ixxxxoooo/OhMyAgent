// @author ixxxxoooo
// 融合模式外框换算测试:沿用来源外框、小于最小尺寸时放大并保持顶边、无效外框返回 nil。

import CoreGraphics
import Testing
@testable import IDEKit

@Suite("融合模式外框")
struct FusionFrameTests {
    private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    private let minSize = CGSize(width: 900, height: 600)

    @Test("来源外框足够大时原样沿用")
    func keepsSource() {
        let source = CGRect(x: 100, y: 80, width: 1200, height: 760)
        #expect(FusionFrame.adopted(source, minSize: minSize, screens: screens) == source)
    }

    @Test("来源小于最小尺寸:放大到最小尺寸,顶边保持不动")
    func growsToMinimumKeepingTop() throws {
        let source = CGRect(x: 100, y: 300, width: 700, height: 400)
        let result = try #require(FusionFrame.adopted(source, minSize: minSize, screens: screens))
        #expect(result.width == 900 && result.height == 600)
        #expect(result.minX == 100)
        #expect(result.maxY == source.maxY)
    }

    @Test("无效外框返回 nil:空尺寸、完全在屏幕外、非有限数")
    func rejectsInvalid() {
        #expect(FusionFrame.adopted(.zero, minSize: minSize, screens: screens) == nil)
        #expect(FusionFrame.adopted(CGRect(x: 5000, y: 5000, width: 1000, height: 700), minSize: minSize, screens: screens) == nil)
        #expect(FusionFrame.adopted(CGRect(x: CGFloat.nan, y: 0, width: 1000, height: 700), minSize: minSize, screens: screens) == nil)
        #expect(FusionFrame.adopted(CGRect(x: 0, y: 0, width: 1000, height: 700), minSize: minSize, screens: []) == nil)
    }

    @Test("与屏幕部分相交也可沿用(窗口一部分拖出屏幕)")
    func partiallyOffscreen() {
        let source = CGRect(x: 1200, y: 100, width: 1000, height: 700)
        #expect(FusionFrame.adopted(source, minSize: minSize, screens: screens) == source)
    }
}
