// @author ixxxxoooo
// Git 历史行渲染测试:泳道图与提交行能渲染出内容(设置 GH_DUMP 时落盘 PNG 供人工查看)。

import AppKit
import GitKit
import SwiftUI
import Testing

@testable import OhMyAgentApp

@MainActor
@Suite("Git 历史渲染")
struct GitHistoryRenderTests {
    private func commit(_ name: String, _ parents: [String], refs: [String] = []) -> GitCommit {
        GitCommit(hash: name + String(repeating: "0", count: 40 - name.count), parents: parents.map { $0 + String(repeating: "0", count: 40 - $0.count) },
                  author: "Tester", email: "t@x", date: Date().addingTimeInterval(-3600), subject: "提交 \(name)", refs: refs)
    }

    @Test("分叉合并的行能渲染")
    func renders() throws {
        let rows = GitGraph.layout([
            commit("m", ["b", "c"], refs: ["HEAD -> main", "tag: v1"]),
            commit("b", ["a"]), commit("c", ["a"], refs: ["origin/feature"]), commit("a", []),
        ])
        let width = CGFloat(rows.map(\.laneCount).max() ?? 1) * 14 + 10
        let view = VStack(spacing: 0) {
            ForEach(rows) { row in CommitRow(row: row, laneWidth: width, isSelected: row.commit.subject.hasSuffix("b")) }
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height >= 100)
        if let path = ProcessInfo.processInfo.environment["GH_DUMP"],
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
