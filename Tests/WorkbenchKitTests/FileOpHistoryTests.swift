// @author ixxxxoooo
// 文件操作撤销栈与回退执行器测试。

import Foundation
import Testing
@testable import WorkbenchKit

@Suite("FileOpHistory")
struct FileOpHistoryTests {
    private func makeTemp() throws -> String {
        let dir = NSTemporaryDirectory() + "oma-fileop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("栈按后进先出,超出容量丢弃最旧")
    func stackOrder() {
        var history = FileOpHistory()
        history.push(FileOpGroup(title: "空", ops: []))
        #expect(!history.canUndo)
        for index in 0..<(FileOpHistory.capacity + 5) {
            history.push(FileOpGroup(title: "\(index)", ops: [.created(path: "/x/\(index)")]))
        }
        #expect(history.popLast()?.title == "\(FileOpHistory.capacity + 4)")
        var count = 1
        while history.popLast() != nil { count += 1 }
        #expect(count == FileOpHistory.capacity)
    }

    @Test("撤销移动:文件夹回到原位置")
    func revertMove() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/Resources", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Scripts", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: root + "/Resources", toPath: root + "/Scripts/Resources")
        let failures = FileOpReverter.revert(FileOpGroup(title: "移动", ops: [.move(from: root + "/Resources", to: root + "/Scripts/Resources")]))
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root + "/Resources"))
        #expect(!FileManager.default.fileExists(atPath: root + "/Scripts/Resources"))
    }

    @Test("原位置已有同名项目时不覆盖并报告失败")
    func revertDoesNotOverwrite() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/a"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: root + "/b"))
        let failures = FileOpReverter.revert(FileOpGroup(title: "移动", ops: [.move(from: root + "/a", to: root + "/b")]))
        #expect(failures.count == 1)
        #expect(try String(contentsOfFile: root + "/a", encoding: .utf8) == "a")
    }

    @Test("多步操作按相反顺序回退(替换:先移回再还原被替换项)")
    func revertReplaceOrder() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("src".utf8).write(to: URL(fileURLWithPath: root + "/src"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: root + "/stash"))
        // 模拟:dest 原为 old(已被移走到 stash),src 被移到 dest
        try FileManager.default.moveItem(atPath: root + "/src", toPath: root + "/dest")
        let group = FileOpGroup(title: "替换", ops: [.trashed(original: root + "/dest", trashed: root + "/stash"), .move(from: root + "/src", to: root + "/dest")])
        #expect(FileOpReverter.revert(group).isEmpty)
        #expect(try String(contentsOfFile: root + "/src", encoding: .utf8) == "src")
        #expect(try String(contentsOfFile: root + "/dest", encoding: .utf8) == "old")
    }
}
