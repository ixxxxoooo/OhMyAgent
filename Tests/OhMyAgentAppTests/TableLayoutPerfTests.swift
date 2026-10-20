// @author ixxxxoooo
// Markdown 表格排版耗时守卫(debug 构建的宽松上限;release 预算 60×7 首帧排版 ≤ 30ms)。

import AppKit
import Foundation
import Testing
@testable import OhMyAgentApp

@MainActor
@Suite("表格排版性能")
struct TableLayoutPerfTests {
    /// 构造 `rows` 行 × `columns` 列的表格并完整排版,返回毫秒数。
    private func layoutMilliseconds(rows: Int, columns: Int) -> Double {
        let header = (0..<columns).map { "列\($0)" }
        let body = (0..<rows).map { row in (0..<columns).map { "行\(row)列\($0) `code` **粗体** 内容文字" } }
        let clock = ContinuousClock()
        let started = clock.now
        let text = OMLeafContent.table(header: header, rows: body)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return Double((clock.now - started).components.attoseconds) / 1e15
    }

    @Test("60×7 表格从构造到排版完成不超过 debug 上限")
    func sixtyBySeven() {
        _ = layoutMilliseconds(rows: 5, columns: 3)   // 预热字体与类型元数据
        let elapsed = layoutMilliseconds(rows: 60, columns: 7)
        #expect(elapsed < 400, "60×7 表格排版耗时 \(elapsed)ms")
    }

    @Test("耗时随行数近似线性增长(排版不是平方级)")
    func roughlyLinear() {
        _ = layoutMilliseconds(rows: 5, columns: 3)
        let small = layoutMilliseconds(rows: 30, columns: 7)
        let large = layoutMilliseconds(rows: 120, columns: 7)
        #expect(large < max(small, 5) * 8, "30 行 \(small)ms,120 行 \(large)ms")
    }
}
