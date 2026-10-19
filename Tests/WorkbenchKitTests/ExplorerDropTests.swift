// @author ixxxxoooo
// 资源管理器拖放规划:工作区内移动、外部复制、拒绝移入自身、移动后文件标签改指新路径。

import Foundation
import Testing

@testable import WorkbenchKit

@Suite("资源管理器拖放")
struct ExplorerDropTests {
    private let root = "/p/项目"

    @Test("工作区内拖动为移动;外部拖入为复制;目标为落点文件夹 + 原文件名")
    func moveAndCopy() {
        let plan = ExplorerDropPlan.make(sources: ["/p/项目/a/说明.md", "/Users/me/Desktop/外部 文件.txt"], into: "/p/项目/b", workspaceRoots: [root])
        #expect(plan.transfers == [
            ExplorerTransfer(source: "/p/项目/a/说明.md", destination: "/p/项目/b/说明.md", kind: .move),
            ExplorerTransfer(source: "/Users/me/Desktop/外部 文件.txt", destination: "/p/项目/b/外部 文件.txt", kind: .copy),
        ])
        #expect(plan.rejected.isEmpty)
    }

    @Test("拖回原文件夹不操作;不能移到自身或子文件夹;同时拖父子目录只处理父目录")
    func edgeCases() {
        #expect(ExplorerDropPlan.make(sources: ["/p/项目/a/x.go"], into: "/p/项目/a", workspaceRoots: [root]).transfers.isEmpty)
        let selfDrop = ExplorerDropPlan.make(sources: ["/p/项目/a", "/p/项目/b"], into: "/p/项目/a/sub", workspaceRoots: [root])
        #expect(selfDrop.rejected == ["/p/项目/a"])
        #expect(selfDrop.transfers.map(\.source) == ["/p/项目/b"])
        let nested = ExplorerDropPlan.make(sources: ["/p/项目/a", "/p/项目/a/x.go", "/p/项目/a"], into: "/p/项目/c", workspaceRoots: [root])
        #expect(nested.transfers.map(\.source) == ["/p/项目/a"])
        // 附加文件夹也算工作区内
        let extra = ExplorerDropPlan.make(sources: ["/q/lib/m.swift"], into: "/p/项目", workspaceRoots: [root, "/q/lib"])
        #expect(extra.transfers.first?.kind == .move)
    }

    @Test("移动后:指向旧路径及其内部的文件标签改指新路径,其他标签不变")
    func retargetTabs() {
        var dock = DockLayout()
        let a = dock.open(.file(path: "/p/项目/a/说明.md"), title: "说明.md")
        let inside = dock.open(.file(path: "/p/项目/a/sub/x.go"), title: "x.go")
        let other = dock.open(.file(path: "/p/项目/ab.txt"), title: "ab.txt")
        dock.retargetFiles(from: "/p/项目/a", to: "/p/项目/b/a")
        let kinds = Dictionary(uniqueKeysWithValues: dock.allTabs.map { ($0.id, $0.kind) })
        #expect(kinds[a] == .file(path: "/p/项目/b/a/说明.md"))
        #expect(kinds[inside] == .file(path: "/p/项目/b/a/sub/x.go"))
        #expect(kinds[other] == .file(path: "/p/项目/ab.txt"))
    }
}
