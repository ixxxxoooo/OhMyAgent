// @author ixxxxoooo
// 项目栏窗口化布局测试。

import Testing
@testable import WorkbenchKit

@Suite("项目栏行布局")
struct SidebarRowLayoutTests {
    private let layout = SidebarRowLayout(heights: [32, 32, 26, 32, 32, 32, 26, 32, 32, 32], bottomInset: 16)

    @Test("前缀和偏移与总高度")
    func offsets() {
        #expect(layout.count == 10)
        #expect(layout.offsets[0] == 0)
        #expect(layout.offsets[3] == 90)
        #expect(layout.totalHeight == 32 * 7 + 26 * 2 + 16 + 32)
    }

    @Test("窗口覆盖可见范围并按缓冲扩展")
    func window() {
        // 偏移 100 落在第 3 行(90...122)内;视口 60 → 底边 160 落在第 5 行顶部(154)之后
        let range = layout.window(offset: 100, viewport: 60, overscan: 0)
        #expect(range.contains(3))
        #expect(range.contains(5))
        #expect(layout.window(offset: 100, viewport: 60, overscan: 2).lowerBound == 1)
        #expect(layout.window(offset: 0, viewport: 10_000, overscan: 3) == 0..<10)
        #expect(layout.window(offset: 99_999, viewport: 100, overscan: 0).upperBound == 10)
    }

    @Test("上下占位高度与挂载行拼起来恰好等于总高度")
    func spacersAddUp() {
        for offset in stride(from: 0.0, through: 420, by: 17) {
            let range = layout.window(offset: offset, viewport: 90, overscan: 1)
            let mounted = layout.offsets[range].enumerated().reduce(0.0) { sum, pair in
                sum + (pair.offset + range.lowerBound + 1 < layout.count
                    ? layout.offsets[pair.offset + range.lowerBound + 1] - pair.element
                    : layout.totalHeight - 16 - pair.element)
            }
            let total = layout.leadingHeight(for: range) + mounted + layout.trailingHeight(for: range)
            #expect(abs(total - layout.totalHeight) < 0.001, "offset=\(offset)")
        }
    }

    @Test("空布局")
    func empty() {
        let empty = SidebarRowLayout(heights: [])
        #expect(empty.window(offset: 0, viewport: 100).isEmpty)
        #expect(empty.totalHeight == 0)
        #expect(empty.trailingHeight(for: 0..<0) == 0)
    }
}
