// @author ixxxxoooo
// 工作区文件监听测试:噪声过滤、事件折算,以及真实 FSEvents 下新增文件能被发现。

import Foundation
import Synchronization
import Testing
@testable import WorkbenchKit

@Suite("WorkspaceWatcher")
struct WorkspaceWatcherTests {
    private let root = "/Users/me/project"

    @Test("噪声路径:.git 内部、node_modules 包内部、构建缓存被忽略")
    func noise() {
        #expect(WorkspaceWatchFilter.isNoise(root + "/.git/index.lock", root: root))
        #expect(WorkspaceWatchFilter.isNoise(root + "/node_modules/react/index.js", root: root))
        #expect(WorkspaceWatchFilter.isNoise(root + "/.build/debug/app", root: root))
        #expect(!WorkspaceWatchFilter.isNoise(root + "/node_modules/react", root: root))
        #expect(!WorkspaceWatchFilter.isNoise(root + "/src/main.swift", root: root))
        #expect(!WorkspaceWatchFilter.isNoise(root + "/build/out.txt", root: root))
    }

    @Test("折算:只有增删改名影响目录列表,目标是文件的父目录")
    func foldDirectories() {
        let events = [
            WorkspaceFSEvent(path: root + "/src/new.swift", changesListing: true),
            WorkspaceFSEvent(path: root + "/src/edited.swift", changesListing: false),
            WorkspaceFSEvent(path: root + "/top.txt", changesListing: true),
            WorkspaceFSEvent(path: root + "/.git/HEAD", changesListing: true),
        ]
        let batch = WorkspaceWatchFilter.fold(events, root: root)
        #expect(batch.directories == [root + "/src", root])
        #expect(!batch.needsFullRefresh)
    }

    @Test("折算:只改内容的文件置位 touched(不影响目录列表),噪声路径不触发")
    func foldTouched() {
        let edited = WorkspaceWatchFilter.fold([WorkspaceFSEvent(path: root + "/src/a.swift", changesListing: false)], root: root)
        #expect(edited.touched && !edited.gitChanged && edited.directories.isEmpty && !edited.isEmpty)
        let noise = WorkspaceWatchFilter.fold([
            WorkspaceFSEvent(path: root + "/.build/debug/app", changesListing: false),
            WorkspaceFSEvent(path: root + "/node_modules/react/index.js", changesListing: false),
            WorkspaceFSEvent(path: root + "/.git/objects/ab/cdef", changesListing: true),
        ], root: root)
        #expect(noise.isEmpty)
    }

    @Test("折算:.git 的 index/HEAD/refs 置位 gitChanged,锁文件与对象库不算")
    func foldGitState() {
        for name in ["index", "HEAD", "refs/heads/main", "MERGE_HEAD"] {
            let batch = WorkspaceWatchFilter.fold([WorkspaceFSEvent(path: root + "/.git/" + name, changesListing: false)], root: root)
            #expect(batch.gitChanged && !batch.touched, "\(name)")
        }
        #expect(!WorkspaceWatchFilter.isGitStateChange(root + "/.git/index.lock", root: root))
        #expect(!WorkspaceWatchFilter.isGitStateChange(root + "/.git/objects/ab/cdef", root: root))
        #expect(!WorkspaceWatchFilter.isGitStateChange(root + "/src/index", root: root))
    }

    @Test("需要整树重扫或目录过多时退化为整体刷新")
    func foldFallback() {
        let rescan = WorkspaceWatchFilter.fold([WorkspaceFSEvent(path: root, changesListing: false, mustRescan: true)], root: root)
        #expect(rescan.needsFullRefresh)
        let many = (0...WorkspaceWatchFilter.maxDirectories).map { WorkspaceFSEvent(path: root + "/d\($0)/f", changesListing: true) }
        let batch = WorkspaceWatchFilter.fold(many, root: root)
        #expect(batch.needsFullRefresh && batch.directories.isEmpty)
    }

    @Test("真实文件系统:新建文件后收到所在目录的变化(路径使用项目根的写法)")
    func realFileSystem() async throws {
        let base = NSTemporaryDirectory() + "oma-watch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let seen = Mutex<Set<String>>([])
        let watcher = WorkspaceWatcher(root: base, debounce: 0.05) { batch in
            seen.withLock { $0.formUnion(batch.directories) }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: URL(fileURLWithPath: base + "/sub/a.txt"))
        var found = false
        for _ in 0..<40 where !found {
            try await Task.sleep(for: .milliseconds(100))
            found = seen.withLock { $0.contains(base + "/sub") }
        }
        #expect(found, "应当收到 sub 目录的变化,实际: \(seen.withLock { $0 })")
    }
}
