// @author ixxxxoooo
// 最近文件记录测试。

import Foundation
import Testing
@testable import ChatKit

@Suite("最近文件")
struct RecentFilesTests {
    private func makeDefaults() -> UserDefaults {
        let name = "oma.test.recentfiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("同路径去重并置顶,按项目根过滤")
    func recordAndFilter() {
        let defaults = makeDefaults()
        RecentStore.recordFile("/p1/a.swift", defaults)
        RecentStore.recordFile("/p2/b.swift", defaults)
        RecentStore.recordFile("/p1/c.swift", defaults)
        RecentStore.recordFile("/p1/a.swift", defaults)
        let list = RecentStore.files(under: ["/p1"], exists: { _ in true }, defaults)
        #expect(list == ["/p1/a.swift", "/p1/c.swift"])
        #expect(RecentStore.files(under: ["/p2"], exists: { _ in true }, defaults) == ["/p2/b.swift"])
        #expect(RecentStore.files(under: [], exists: { _ in true }, defaults).isEmpty)
    }

    @Test("不存在的文件被过滤,条数受 limit 限制;前缀相近的项目不串")
    func existsAndLimit() {
        let defaults = makeDefaults()
        for index in 0..<5 { RecentStore.recordFile("/p/f\(index)", defaults) }
        RecentStore.recordFile("/pp/x", defaults)
        let list = RecentStore.files(under: ["/p"], limit: 2, exists: { $0 != "/p/f4" }, defaults)
        #expect(list == ["/p/f3", "/p/f2"])
    }

    @Test("移除目录会带走其下的记录")
    func removeDirectory() {
        let defaults = makeDefaults()
        RecentStore.recordFile("/p/dir/a", defaults)
        RecentStore.recordFile("/p/other", defaults)
        RecentStore.removeFiles(at: "/p/dir", defaults)
        #expect(RecentStore.files(under: ["/p"], exists: { _ in true }, defaults) == ["/p/other"])
    }

    @Test("记录总数有上限")
    func cap() {
        let defaults = makeDefaults()
        for index in 0..<(RecentStore.maxRecentFiles + 5) { RecentStore.recordFile("/p/f\(index)", defaults) }
        let list = RecentStore.files(under: ["/p"], limit: 1000, exists: { _ in true }, defaults)
        #expect(list.count == RecentStore.maxRecentFiles)
    }
}
