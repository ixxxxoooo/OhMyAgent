// @author ygw
// 标签保活 LRU:最近使用的标签保持挂载,会话标签常驻,已关闭的标签被清理。

import Foundation
import Testing

@testable import WorkbenchKit

@Suite("标签保活")
struct TabKeepAliveTests {
    private func files(_ count: Int) -> [WorkbenchTab] {
        (0..<count).map { WorkbenchTab(kind: .file(path: "/tmp/f\($0).txt"), title: "f\($0)") }
    }

    @Test("超过上限后卸载最久未使用的文件标签")
    func evictsLeastRecentlyUsed() {
        let tabs = files(8)
        var keep = TabKeepAlive(limit: 3)
        for tab in tabs { keep.activate(tab.id, in: tabs) }
        let mounted = keep.mounted(in: tabs, active: tabs[7].id).map(\.title)
        #expect(mounted == ["f5", "f6", "f7"])
    }

    @Test("切回旧标签后它成为最近使用")
    func revisitRefreshes() {
        let tabs = files(4)
        var keep = TabKeepAlive(limit: 3)
        for tab in tabs.prefix(3) { keep.activate(tab.id, in: tabs) }
        keep.activate(tabs[0].id, in: tabs)
        keep.activate(tabs[3].id, in: tabs)
        let mounted = Set(keep.mounted(in: tabs, active: tabs[3].id).map(\.title))
        #expect(mounted == ["f0", "f2", "f3"])
    }

    @Test("会话标签常驻,不占用上限")
    func chatIsResident() {
        let chat = WorkbenchTab(kind: .chat(projectID: "/p"), title: "会话")
        let tabs = [chat] + files(5)
        var keep = TabKeepAlive(limit: 2)
        keep.activate(chat.id, in: tabs)
        for tab in tabs.dropFirst() { keep.activate(tab.id, in: tabs) }
        let mounted = keep.mounted(in: tabs, active: tabs[5].id).map(\.title)
        #expect(mounted == ["会话", "f3", "f4"])
        #expect(mounted.contains("会话"))
        #expect(mounted.count == 3)
    }

    @Test("已关闭的标签被清理,激活标签一定挂载")
    func closedTabsPruned() {
        var tabs = files(3)
        var keep = TabKeepAlive(limit: 5)
        for tab in tabs { keep.activate(tab.id, in: tabs) }
        let removed = tabs.remove(at: 1)
        keep.activate(tabs[0].id, in: tabs)
        #expect(!keep.order.contains(removed.id))
        // 尚未记录的激活标签也必须在挂载列表里
        let fresh = WorkbenchTab(kind: .file(path: "/tmp/new"), title: "new")
        tabs.append(fresh)
        #expect(keep.mounted(in: tabs, active: fresh.id).contains { $0.id == fresh.id })
    }
}
