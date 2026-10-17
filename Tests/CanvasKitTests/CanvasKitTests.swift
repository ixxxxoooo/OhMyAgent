// @author ixxxxoooo
// CanvasKit 测试:宽松解码、规范化、校验错误、存储往返与标识安全。

import Foundation
import Testing

@testable import CanvasKit

@Suite("Canvas 模型与存储")
struct CanvasKitTests {
    private func parse(_ json: String) throws -> [CanvasBlock] { try CanvasParser.parseBlocks(Data(json.utf8)) }

    @Test("宽松解码:数字写成字符串、别名字段、表格行补齐")
    func lenientDecode() throws {
        let blocks = try parse("""
        [{"type":"heading","text":"概览","level":9},
         {"type":"table","columns":["名称","数量"],"rows":[["a",1],["b"],["c",2,3]]},
         {"type":"chart","kind":"bar","labels":["一","二"],"series":[{"name":"s","values":["1,200",3]}]},
         {"type":"stats","items":[{"label":"请求","value":42,"delta":"+3%","tone":"success"}]}]
        """)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading(text: "概览", level: 3))
        guard case .table(let table) = blocks[1] else { Issue.record("应是表格"); return }
        #expect(table.rows == [["a", "1"], ["b", ""], ["c", "2"]])
        guard case .chart(let chart) = blocks[2] else { Issue.record("应是图表"); return }
        #expect(chart.series[0].values == [1200, 3])
        guard case .stats(let stats) = blocks[3] else { Issue.record("应是统计"); return }
        #expect(stats[0].value == "42" && stats[0].tone == .success)
    }

    @Test("错误带路径,便于模型重试")
    func errorsCarryPath() {
        #expect(throws: CanvasError.self) { try parse(#"[{"type":"bogus"}]"#) }
        do { _ = try parse(#"[{"type":"heading","text":"x"},{"type":"chart","kind":"bar","labels":["a","b"],"series":[{"name":"s","values":[1]}]}]"#) }
        catch let error as CanvasError { #expect(error.message.contains("blocks[1].series[0]")) } catch { Issue.record("意外错误") }
        do { _ = try parse(#"[{"type":"chart","kind":"radar","labels":["a"],"series":[]}]"#) }
        catch let error as CanvasError { #expect(error.message.contains("bar/line/area/pie")) } catch { Issue.record("意外错误") }
        #expect(throws: CanvasError.self) { try parse(#"[{"type":"image","source":"file:///etc/passwd"}]"#) }
        #expect(throws: CanvasError.self) { try parse(#"[{"type":"pie"}]"#) }
    }

    @Test("规模与嵌套上限")
    func limits() throws {
        let many = "[" + Array(repeating: #"{"type":"divider"}"#, count: CanvasLimits.maxBlocks + 1).joined(separator: ",") + "]"
        #expect(throws: CanvasError.self) { try parse(many) }
        let deep = #"[{"type":"section","title":"1","blocks":[{"type":"section","title":"2","blocks":[{"type":"section","title":"3","blocks":[{"type":"divider"}]}]}]}]"#
        #expect(throws: CanvasError.self) { try parse(deep) }
        #expect(throws: CanvasError.self) { try parse(#"[{"type":"mermaid","text":"  "}]"#) }
        #expect(throws: CanvasError.self) { try parse(#"[{"type":"chart","kind":"pie","labels":["a"],"series":[{"name":"x","values":[1]},{"name":"y","values":[2]}]}]"#) }
    }

    @Test("编码再解码保持一致(含嵌套分区)")
    func roundTrip() throws {
        let blocks: [CanvasBlock] = [
            .markdown("**粗体**"), .callout(tone: .warning, title: "注意", text: "内容"),
            .section(title: "详情", collapsed: true, blocks: [.code(language: "swift", text: "let a = 1"), .divider]),
            .image(source: "/tmp/a.png", caption: "图"), .mermaid("graph TD; A-->B"),
        ]
        let data = try JSONEncoder().encode(blocks)
        #expect(try CanvasParser.parseBlocks(data) == blocks)
    }

    @Test("存储:创建/更新/追加/列表/删除,标识安全")
    func storeLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CanvasStore(directory: dir)
        let doc = try store.create(title: "性能 Report 2026", blocks: [.markdown("hi")], projectPath: "/p")
        #expect(CanvasStore.isValid(id: doc.id) && doc.id.hasPrefix("report-2026-"))
        let updated = try store.update(id: doc.id, title: "新标题", blocks: nil, appendBlocks: [.divider])
        #expect(updated.revision == 2 && updated.title == "新标题" && updated.blocks.count == 2)
        let loaded = try store.load(id: doc.id)
        #expect(loaded.blocks == updated.blocks && loaded.projectPath == "/p")
        #expect(store.list(projectPath: "/p").map(\.id) == [doc.id])
        #expect(store.list(projectPath: "/other").isEmpty)
        #expect(throws: CanvasError.self) { try store.load(id: "../etc/passwd") }
        #expect(throws: CanvasError.self) { try store.create(title: "  ", blocks: [], projectPath: nil) }
        store.delete(id: doc.id)
        #expect(store.list().isEmpty)
    }

    @Test("中文标题回退到 canvas 前缀")
    func chineseTitleSlug() {
        #expect(CanvasStore.slug("性能报告") == "canvas")
        #expect(CanvasStore.slug("Q3 -- Sales!!") == "q3-sales")
    }
}
