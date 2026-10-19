// @author ixxxxoooo

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("资源管理器扁平化与窗口化")
struct ExplorerFlattenTests {
    private func file(_ path: String) -> FileEntry {
        FileEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }
    private func dir(_ path: String) -> FileEntry {
        FileEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    @Test("只展开的目录显示子项,层级递增且顺序保持")
    func nestedOrder() {
        let children: [String: [FileEntry]] = [
            "/r": [dir("/r/a"), dir("/r/b"), file("/r/z.txt")],
            "/r/a": [file("/r/a/1"), dir("/r/a/sub")],
            "/r/a/sub": [file("/r/a/sub/x")],
            "/r/b": [file("/r/b/2")],
        ]
        let rows = ExplorerFlatten.rows(sources: [ExplorerSource(root: "/r", showsHeader: false)], children: children, expanded: ["/r/a", "/r/a/sub"])
        #expect(rows.map(\.entry.path) == ["/r/a", "/r/a/1", "/r/a/sub", "/r/a/sub/x", "/r/b", "/r/z.txt"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0, 0])
        #expect(rows.first?.isExpanded == true)
        #expect(rows[4].isExpanded == false)
    }

    @Test("未展开或未加载的目录不产生子行")
    func collapsedAndUnloaded() {
        let children: [String: [FileEntry]] = ["/r": [dir("/r/a")], "/r/a": [file("/r/a/1")]]
        let collapsed = ExplorerFlatten.rows(sources: [ExplorerSource(root: "/r", showsHeader: false)], children: children, expanded: [])
        #expect(collapsed.count == 1)
        let unloaded = ExplorerFlatten.rows(sources: [ExplorerSource(root: "/r", showsHeader: false)], children: ["/r": [dir("/r/a")]], expanded: ["/r/a"])
        #expect(unloaded.count == 1)
        #expect(unloaded[0].isExpanded)
    }

    @Test("附加文件夹显示标题行,折叠时隐藏其内容,子项缩进一层")
    func extraRootHeader() {
        let children: [String: [FileEntry]] = ["/p": [file("/p/a")], "/x": [file("/x/b")]]
        let sources = [ExplorerSource(root: "/p", showsHeader: false), ExplorerSource(root: "/x", showsHeader: true)]
        let open = ExplorerFlatten.rows(sources: sources, children: children, expanded: ["/x"])
        #expect(open.map(\.entry.path) == ["/p/a", "/x", "/x/b"])
        #expect(open[1].isRootHeader && open[1].depth == 0)
        #expect(open[2].depth == 1 && open[2].root == "/x")
        let closed = ExplorerFlatten.rows(sources: sources, children: children, expanded: [])
        #expect(closed.map(\.entry.path) == ["/p/a", "/x"])
    }

    @Test("五千行的扁平目录展平结果完整")
    func largeDirectory() {
        let many = (0..<5000).map { file("/r/big/f\($0)") }
        let rows = ExplorerFlatten.rows(sources: [ExplorerSource(root: "/r", showsHeader: false)],
                                        children: ["/r": [dir("/r/big")], "/r/big": many], expanded: ["/r/big"])
        #expect(rows.count == 5001)
        #expect(rows.last?.entry.path == "/r/big/f4999")
    }

    @Test("视口换算:首个可见行与可见行数")
    func viewportMath() {
        let a = ExplorerFlatten.viewport(offset: 0, viewport: 220, rowHeight: 22)
        #expect(a.first == 0 && a.count == 11)
        let b = ExplorerFlatten.viewport(offset: 110, viewport: 100, rowHeight: 22)
        #expect(b.first == 5)
        let negative = ExplorerFlatten.viewport(offset: -30, viewport: 100, rowHeight: 22)
        #expect(negative.first == 0)
        #expect(ExplorerFlatten.viewport(offset: 10, viewport: 100, rowHeight: 0).count == 0)
    }

    @Test("窗口区间:带缓冲并限制在有效范围内")
    func windowRange() {
        #expect(ExplorerFlatten.window(first: 100, visibleCount: 20, total: 5000, overscan: 8) == 92..<128)
        #expect(ExplorerFlatten.window(first: 0, visibleCount: 20, total: 5000, overscan: 8) == 0..<28)
        #expect(ExplorerFlatten.window(first: 4990, visibleCount: 20, total: 5000, overscan: 8) == 4982..<5000)
        #expect(ExplorerFlatten.window(first: 9000, visibleCount: 20, total: 5000, overscan: 8).isEmpty)
        #expect(ExplorerFlatten.window(first: 0, visibleCount: 10, total: 0).isEmpty)
        #expect(ExplorerFlatten.window(first: 3, visibleCount: 10, total: 5, overscan: 8) == 0..<5)
    }
}
