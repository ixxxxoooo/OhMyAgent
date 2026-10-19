// @author ixxxxoooo

import Testing
@testable import WorkbenchKit

@Suite("最小模式")
struct CompactLayoutTests {
    @Test("变窄自动收起,拉宽后恢复")
    func collapseAndRestore() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = true
        layout.rightVisible = true
        policy.update(width: 700, layout: &layout)
        #expect(policy.isCompact && !layout.leftVisible && !layout.rightVisible)
        policy.update(width: 1000, layout: &layout)
        #expect(!policy.isCompact && layout.leftVisible && layout.rightVisible)
    }

    @Test("手动收起的面板不会被自动展开")
    func manualStaysClosed() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = false
        layout.rightVisible = false
        policy.update(width: 600, layout: &layout)
        policy.update(width: 1000, layout: &layout)
        #expect(!layout.leftVisible && !layout.rightVisible)
    }

    @Test("回差区间内不抖动")
    func hysteresis() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = true
        policy.update(width: 700, layout: &layout)
        policy.update(width: 800, layout: &layout)
        #expect(policy.isCompact && !layout.leftVisible)
    }

    @Test("宽度归档位:阈值边界")
    func bucketBoundaries() {
        #expect(CompactLayout.bucket(for: 0) == .invalid)
        #expect(CompactLayout.bucket(for: -5) == .invalid)
        #expect(CompactLayout.bucket(for: .infinity) == .invalid)
        #expect(CompactLayout.bucket(for: 500) == .compact)
        #expect(CompactLayout.bucket(for: CompactLayout.threshold - 0.5) == .compact)
        #expect(CompactLayout.bucket(for: CompactLayout.threshold) == .hysteresis)
        #expect(CompactLayout.bucket(for: CompactLayout.exitWidth - 0.5) == .hysteresis)
        #expect(CompactLayout.bucket(for: CompactLayout.exitWidth) == .regular)
        #expect(CompactLayout.bucket(for: 2000) == .regular)
    }

    @Test("代表宽度与原行为等价:按档位更新 = 按原宽度更新")
    func bucketEquivalentToWidth() {
        for widths in [[1000.0, 700, 800, 1000], [600, 790, 830, 770, 900], [1200, 819, 779, 821]] {
            var byWidth = CompactLayout(), byBucket = CompactLayout()
            var layoutA = WorkbenchLayout(), layoutB = WorkbenchLayout()
            layoutA.leftVisible = true; layoutA.rightVisible = true
            layoutB = layoutA
            var lastBucket: CompactLayout.Bucket?
            for width in widths {
                byWidth.update(width: width, layout: &layoutA)
                let bucket = CompactLayout.bucket(for: width)
                // 视图层的行为:档位不变则不触发 action
                if bucket != lastBucket, let representative = bucket.representativeWidth {
                    byBucket.update(width: representative, layout: &layoutB)
                }
                lastBucket = bucket
                #expect(layoutA == layoutB)
                #expect(byWidth.isCompact == byBucket.isCompact)
            }
        }
    }

    @Test("档位不变的更新不改变布局")
    func sameBucketNoChange() {
        var policy = CompactLayout()
        var layout = WorkbenchLayout()
        layout.leftVisible = true
        let before = layout
        policy.update(width: CompactLayout.exitWidth, layout: &layout)
        #expect(layout == before)
    }
}
