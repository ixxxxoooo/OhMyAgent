// @author ixxxxoooo
// 画布渲染测试:演示画布(覆盖全部块类型)能渲染出有尺寸的内容;表格排序状态机与数值感知排序。

import AppKit
import CanvasKit
import DemoKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Canvas 渲染")
struct CanvasViewTests {
    @Test("演示画布含全部块类型并能渲染")
    func rendersDemoDocument() {
        let document = DemoCanvas.document(projectPath: "/tmp/none")
        let types = Set(document.blocks.flatMap { block -> [String] in
            if case .section(_, _, let children) = block { return [block.typeName] + children.map(\.typeName) }
            return [block.typeName]
        })
        for type in ["heading", "markdown", "stats", "table", "chart", "callout", "code", "image", "mermaid", "section", "divider"] {
            #expect(types.contains(type), "演示画布缺少块类型 \(type)")
        }
        let renderer = ImageRenderer(content: CanvasBodyView(document: document).frame(width: 760))
        renderer.scale = 1
        let image = renderer.nsImage
        #expect((image?.size.height ?? 0) > 400)
    }

    @Test("表格排序:升序 → 降序 → 取消,数值按大小而非字典序")
    func tableSort() {
        let rows = [["a", "10"], ["b", "9"], ["c", "1,200"]]
        var sort = CanvasTableSort()
        sort.toggle(1)
        #expect(sort.apply(to: rows).map { $0[0] } == ["b", "a", "c"])
        sort.toggle(1)
        #expect(sort.apply(to: rows).map { $0[0] } == ["c", "a", "b"])
        sort.toggle(1)
        #expect(sort.column == nil)
        #expect(sort.apply(to: rows) == rows)
    }
}
