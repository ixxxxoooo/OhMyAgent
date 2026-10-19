// @author ixxxxoooo
// fs/write_text_file 的工作区边界:按真实路径判断,软链不能把写入带出工作区。

import Foundation
import Testing

@testable import ChatKit

@Suite("工作区写入边界")
struct WorkspaceWriteGuardTests {
    @Test("工作区内的普通路径与尚不存在的子目录允许写入")
    func insidePaths() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wsguard-\(UUID().uuidString)")
        let root = base.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SessionDelegate.isInsideWorkspace(root.path + "/a.txt", root: root.path))
        #expect(SessionDelegate.isInsideWorkspace(root.path + "/new/dir/a.txt", root: root.path))
        #expect(!SessionDelegate.isInsideWorkspace(root.path + "/../escape.txt", root: root.path))
        #expect(!SessionDelegate.isInsideWorkspace(base.path + "/ws-sibling/a.txt", root: root.path))
    }

    @Test("经工作区内的软链指向外部(含悬空软链)一律拒绝")
    func symlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oma-wsguard-\(UUID().uuidString)")
        let root = base.appendingPathComponent("ws")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(atPath: root.path + "/link", withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: root.path + "/dangling", withDestinationPath: outside.path + "/missing")
        #expect(!SessionDelegate.isInsideWorkspace(root.path + "/link/a.txt", root: root.path))
        #expect(!SessionDelegate.isInsideWorkspace(root.path + "/link/new/a.txt", root: root.path))
        #expect(!SessionDelegate.isInsideWorkspace(root.path + "/dangling/a.txt", root: root.path))
        // 工作区本身经软链打开时,里面的路径仍算在内
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        #expect(SessionDelegate.isInsideWorkspace(root.path + "/a.txt", root: alias.path))
    }
}
