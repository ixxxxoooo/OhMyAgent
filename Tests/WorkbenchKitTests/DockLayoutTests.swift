// @author ixxxxoooo
// 停靠布局模型测试:打开去重、预览替换、关闭折叠、移动、分屏、落点几何、持久化与损坏恢复。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("停靠布局")
struct DockLayoutTests {
    private func file(_ name: String) -> TabKind { .file(path: "/p/\(name)") }

    @Test("初始为一个空组;打开标签后激活并聚焦")
    func openBasics() {
        var dock = DockLayout()
        #expect(dock.groups.count == 1 && dock.allTabs.isEmpty)
        let a = dock.open(file("a"), title: "a")
        #expect(dock.focusedGroup?.activeID == a)
        let b = dock.open(file("b"), title: "b")
        #expect(dock.focusedGroup?.tabs.map(\.title) == ["a", "b"])
        #expect(dock.focusedGroup?.activeID == b)
    }

    @Test("同内容去重:再次打开只聚焦并更新行号,预览被固化")
    func openDedupes() {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a", preview: true)
        dock.open(file("b"), title: "b")
        let again = dock.open(file("a"), title: "a2", preview: false, line: 42)
        #expect(again == a)
        #expect(dock.allTabs.count == 2)
        let tab = dock.tab(a)
        #expect(tab?.title == "a2" && tab?.line == 42 && tab?.isPreview == false)
        #expect(dock.focusedGroup?.activeID == a)
    }

    @Test("预览标签被下一个预览替换;固定的预览不被替换")
    func previewReplacement() {
        var dock = DockLayout()
        dock.open(file("a"), title: "a", preview: true)
        dock.open(file("b"), title: "b", preview: true)
        #expect(dock.allTabs.map(\.title) == ["b"])
        let b = dock.allTabs[0].id
        dock.togglePinned(b)
        dock.open(file("c"), title: "c", preview: true)
        #expect(dock.allTabs.map(\.title) == ["b", "c"])
        #expect(dock.tab(b)?.isPreview == false)
    }

    @Test("关闭激活标签选择相邻标签;最后一个关闭后保留空根组")
    func closeActivatesNeighbor() {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(file("b"), title: "b")
        let c = dock.open(file("c"), title: "c")
        dock.activate(b)
        dock.close(b)
        #expect(dock.focusedGroup?.activeID == c)
        dock.close(c)
        #expect(dock.focusedGroup?.activeID == a)
        dock.close(a)
        #expect(dock.groups.count == 1 && dock.allTabs.isEmpty)
    }

    @Test("固定标签排在最前,关闭其它时保留")
    func pinning() {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        dock.open(file("b"), title: "b")
        let c = dock.open(file("c"), title: "c")
        dock.togglePinned(c)
        #expect(dock.focusedGroup?.tabs.first?.id == c)
        dock.closeOthers(a)
        #expect(Set(dock.allTabs.map(\.id)) == [a, c])
    }

    @Test("拖到右边缘新建分屏;拖空后折叠回单组")
    func splitAndCollapse() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(file("b"), title: "b")
        let source = try #require(dock.location(of: a)?.group)
        dock.drop(b, onGroup: source, zone: .right)
        #expect(dock.groups.count == 2)
        guard case .split(let split) = dock.root else { Issue.record("根应为分屏"); return }
        #expect(split.axis == .horizontal && split.ratios == [0.5, 0.5])
        #expect(dock.group(dock.location(of: b)!.group)?.tabs.count == 1)
        // 把 b 拖回中心 → 合并,分屏折叠
        dock.drop(b, onGroup: dock.location(of: a)!.group, zone: .center)
        #expect(dock.groups.count == 1)
        if case .group = dock.root {} else { Issue.record("分屏应折叠为单组") }
    }

    @Test("同轴再次分屏并入同一分屏,异轴嵌套")
    func nestedSplits() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(file("b"), title: "b")
        let c = dock.open(file("c"), title: "c")
        let g = try #require(dock.location(of: a)?.group)
        dock.drop(c, onGroup: g, zone: .right)
        dock.drop(b, onGroup: g, zone: .left)   // a 所在组左侧新增 → 同轴并入
        guard case .split(let s) = dock.root else { Issue.record("根应为分屏"); return }
        #expect(s.children.count == 3 && s.axis == .horizontal)
        #expect(abs(s.ratios.reduce(0, +) - 1) < 1e-9)
        let gc = try #require(dock.location(of: c)?.group)
        dock.open(file("d"), title: "d", in: gc)
        let d = try #require(dock.tab(for: file("d"))?.id)
        dock.drop(d, onGroup: gc, zone: .bottom)  // 异轴 → 嵌套竖向分屏
        #expect(dock.groups.count == 4)
        guard case .split(let outer) = dock.root, outer.children.count == 3 else { Issue.record("外层应仍为 3 列"); return }
        #expect(outer.children.contains { if case .split(let inner) = $0 { return inner.axis == .vertical } else { return false } })
    }

    @Test("唯一标签拖到自己组的边缘无效")
    func lonelyTabDrop() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let g = try #require(dock.location(of: a)?.group)
        dock.drop(a, onGroup: g, zone: .left)
        #expect(dock.groups.count == 1)
    }

    @Test("组内重排与跨组移动")
    func moveTabs() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(file("b"), title: "b")
        let c = dock.open(file("c"), title: "c")
        let g = try #require(dock.location(of: a)?.group)
        dock.move(a, toGroup: g, at: 3)
        #expect(dock.focusedGroup?.tabs.map(\.title) == ["b", "c", "a"])
        dock.move(c, toGroup: g, at: 0)
        #expect(dock.focusedGroup?.tabs.map(\.title) == ["c", "b", "a"])
        dock.drop(b, onGroup: g, zone: .right)
        let g2 = try #require(dock.location(of: b)?.group)
        dock.move(a, toGroup: g2)
        #expect(dock.group(g2)?.tabs.map(\.title) == ["b", "a"])
        #expect(dock.group(g)?.tabs.map(\.title) == ["c"])
    }

    @Test("设置分屏比例会归一化并限制最小值")
    func ratios() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(file("b"), title: "b")
        dock.drop(b, onGroup: try #require(dock.location(of: a)?.group), zone: .right)
        guard case .split(let s) = dock.root else { return }
        dock.setRatios([0.01, 3], forSplit: s.id)
        guard case .split(let after) = dock.root else { return }
        #expect(abs(after.ratios.reduce(0, +) - 1) < 1e-9)
        #expect(abs(after.ratios[0] - 0.1) < 1e-9)
        dock.setRatios([1], forSplit: s.id)   // 个数不符被忽略
        guard case .split(let ignored) = dock.root else { return }
        #expect(ignored.ratios == after.ratios)
    }

    @Test("落点几何:中心与四个边缘")
    func dropZones() {
        let size = CGSize(width: 400, height: 300)
        #expect(DockDropZone.zone(at: CGPoint(x: 200, y: 150), in: size) == .center)
        #expect(DockDropZone.zone(at: CGPoint(x: 10, y: 150), in: size) == .left)
        #expect(DockDropZone.zone(at: CGPoint(x: 390, y: 150), in: size) == .right)
        #expect(DockDropZone.zone(at: CGPoint(x: 200, y: 5), in: size) == .top)
        #expect(DockDropZone.zone(at: CGPoint(x: 200, y: 295), in: size) == .bottom)
        #expect(DockDropZone.zone(at: CGPoint(x: -50, y: 600), in: size) != .center)
        #expect(DockDropZone.zone(at: CGPoint(x: 0, y: 0), in: CGSize(width: 0, height: 0)) == .center)
    }

    @Test("持久化往返一致;损坏状态被校正")
    func persistenceAndSanitize() throws {
        var dock = DockLayout()
        let a = dock.open(file("a"), title: "a")
        let b = dock.open(.chat(projectID: "/p", slot: nil), title: "对话")
        dock.drop(b, onGroup: try #require(dock.location(of: a)?.group), zone: .bottom)
        let data = try JSONEncoder().encode(dock)
        let restored = try JSONDecoder().decode(DockLayout.self, from: data)
        #expect(restored == dock)

        // 构造损坏:重复内容、空组、错误的 activeID、比例不匹配
        let dup1 = WorkbenchTab(kind: file("x"), title: "x1"), dup2 = WorkbenchTab(kind: file("x"), title: "x2")
        let broken = DockNode.split(DockSplit(axis: .horizontal,
            children: [.group(TabGroup(tabs: [dup1], activeID: UUID())), .group(TabGroup()), .group(TabGroup(tabs: [dup2]))],
            ratios: [0, -1]))
        let fixed = DockLayout(root: broken)
        #expect(fixed.allTabs.count == 1)
        #expect(fixed.groups.count == 1)
        #expect(fixed.focusedGroup != nil)
        #expect(fixed.focusedGroup?.active?.id == dup1.id)
    }

    @Test("按条件批量关闭标签")
    func closeWhere() {
        var dock = DockLayout()
        dock.open(.chat(projectID: "/p1", slot: nil), title: "c1")
        dock.open(.chat(projectID: "/p2", slot: nil), title: "c2")
        dock.open(.changes(projectID: "/p1"), title: "改动")
        dock.closeTabs { tab in
            switch tab.kind {
            case .chat(let id, _), .changes(let id): return id == "/p1"
            default: return false
            }
        }
        #expect(dock.allTabs.map(\.title) == ["c2"])
    }

    @Test("子 Agent / Agent 终端以新标签页打开:进入当前聚焦组,不分屏,已存在则只激活")
    func openAsTabInFocusedGroup() {
        var dock = DockLayout()
        dock.open(file("x"), title: "x")
        dock.open(.chat(projectID: "p", slot: nil), title: "chat")
        let term = TabKind.agentTerminal(projectID: "p", terminalID: "t1")
        let a = dock.open(term, title: "ls")
        #expect(dock.groups.count == 1)
        #expect(dock.groups.first?.tabs.count == 3 && dock.groups.first?.activeID == a)
        let sub = dock.open(.subagent(projectID: "p", toolCallID: "c1"), title: "sub")
        #expect(dock.groups.count == 1)
        #expect(dock.groups.first?.tabs.count == 4 && dock.groups.first?.activeID == sub)
        // 已存在:不重复,只激活
        let again = dock.open(term, title: "ls")
        #expect(again == a && dock.allTabs.count == 4 && dock.groups.first?.activeID == a)
    }

    @Test("重启恢复时 Agent 终端标签被剔除")
    func agentTerminalNotRestored() {
        var dock = DockLayout()
        dock.open(.chat(projectID: "p", slot: nil), title: "chat")
        dock.open(.agentTerminal(projectID: "p", terminalID: "t"), title: "ls")
        let restored = dock.restoredForLaunch(projectIDs: ["p"])
        #expect(restored.allTabs.count == 1)
    }
}
