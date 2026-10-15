// @author ygw
// DiffKit 测试:Myers 正确性(含随机属性测试)、分块、按块回退、检查点冲突检测。

import Foundation
import Testing

@testable import DiffKit

/// 按操作重建新/旧文本,验证 Diff 的正确性。
private func rebuild(_ diff: FileDiff) -> (old: [String], new: [String]) {
    var old: [String] = [], new: [String] = []
    for op in diff.ops {
        switch op.kind {
        case .equal: old.append(diff.oldLines[op.oldIndex!]); new.append(diff.newLines[op.newIndex!])
        case .delete: old.append(diff.oldLines[op.oldIndex!])
        case .insert: new.append(diff.newLines[op.newIndex!])
        }
    }
    return (old, new)
}

@Suite("行级 Diff")
struct LineDiffTests {
    @Test("相同文本没有差异块")
    func identical() {
        let diff = LineDiff.diff(old: "a\nb\nc\n", new: "a\nb\nc\n")
        #expect(diff.isEmpty)
        #expect(diff.added == 0 && diff.removed == 0)
    }

    @Test("新建文件全部为新增")
    func newFile() {
        let diff = LineDiff.diff(old: nil, new: "x\ny\n")
        #expect(diff.added == 2 && diff.removed == 0)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.allSatisfy { $0.kind == .added })
    }

    @Test("替换一行得到一删一增,行号正确")
    func replaceLine() {
        let diff = LineDiff.diff(old: "a\nb\nc\nd\ne\n", new: "a\nb\nX\nd\ne\n", context: 1)
        #expect(diff.added == 1 && diff.removed == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.header == "@@ -2,3 +2,3 @@")
        let removed = hunk.lines.first { $0.kind == .removed }
        let added = hunk.lines.first { $0.kind == .added }
        #expect(removed?.text == "c" && removed?.oldNumber == 3)
        #expect(added?.text == "X" && added?.newNumber == 3)
    }

    @Test("相距较远的改动分成多个块,较近的合并")
    func hunkGrouping() {
        let old = (1...30).map(String.init).joined(separator: "\n") + "\n"
        var lines = (1...30).map(String.init)
        lines[1] = "two"; lines[28] = "twenty-nine"
        let far = LineDiff.diff(old: old, new: lines.joined(separator: "\n") + "\n", context: 3)
        #expect(far.hunks.count == 2)
        lines = (1...30).map(String.init)
        lines[1] = "two"; lines[5] = "six"
        let near = LineDiff.diff(old: old, new: lines.joined(separator: "\n") + "\n", context: 3)
        #expect(near.hunks.count == 1)
    }

    @Test("随机文本:按操作重建的旧/新文本与输入一致")
    func randomized() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let oldLines = (0..<Int.random(in: 0...40, using: &generator)).map { _ in String(Int.random(in: 0...6, using: &generator)) }
            var newLines = oldLines
            for _ in 0..<Int.random(in: 0...8, using: &generator) {
                switch Int.random(in: 0...2, using: &generator) {
                case 0 where !newLines.isEmpty: newLines.remove(at: Int.random(in: 0..<newLines.count, using: &generator))
                case 1: newLines.insert(String(Int.random(in: 0...9, using: &generator)), at: Int.random(in: 0...newLines.count, using: &generator))
                default: if !newLines.isEmpty { newLines[Int.random(in: 0..<newLines.count, using: &generator)] = "z" }
                }
            }
            let oldText = oldLines.isEmpty ? "" : oldLines.joined(separator: "\n") + "\n"
            let newText = newLines.isEmpty ? "" : newLines.joined(separator: "\n") + "\n"
            let diff = LineDiff.diff(old: oldText, new: newText)
            let rebuilt = rebuild(diff)
            #expect(rebuilt.old == oldLines)
            #expect(rebuilt.new == newLines)
            // 回退全部块应还原旧文本;回退空集合应保持新文本
            #expect(LineDiff.revert(hunks: Set(diff.hunks.map(\.id)), in: diff) == oldText)
            #expect(LineDiff.revert(hunks: [], in: diff) == newText)
        }
    }

    @Test("按块回退:只还原选中的块")
    func partialRevert() {
        let old = (1...30).map(String.init).joined(separator: "\n") + "\n"
        var lines = (1...30).map(String.init)
        lines[1] = "two"; lines[28] = "twenty-nine"
        let new = lines.joined(separator: "\n") + "\n"
        let diff = LineDiff.diff(old: old, new: new)
        #expect(diff.hunks.count == 2)
        let reverted = LineDiff.revert(hunks: [diff.hunks[0].id], in: diff)
        let result = reverted.split(separator: "\n").map(String.init)
        #expect(result[1] == "2")
        #expect(result[28] == "twenty-nine")
    }

    @Test("大文件小改动性能可接受")
    func largeFile() {
        let old = (0..<50_000).map { "line \($0)" }
        var new = old
        new[25_000] = "changed"
        new.insert("inserted", at: 40_000)
        let start = ContinuousClock.now
        let diff = LineDiff.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let elapsed = ContinuousClock.now - start
        #expect(diff.added == 2 && diff.removed == 1)
        #expect(elapsed < .seconds(2))
    }
}

@Suite("检查点")
struct CheckpointTests {
    private func tempFile(_ content: String) throws -> String {
        let path = NSTemporaryDirectory() + "oma-\(UUID().uuidString).txt"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("整文件回退恢复原内容,新建文件回退即删除")
    func fullRevert() async throws {
        let store = CheckpointStore()
        let path = try tempFile("改后\n")
        await store.record(turn: 1, path: path, oldText: "改前\n", newText: "改后\n")
        #expect(await store.revert(path: path) == .reverted)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "改前\n")

        let created = try tempFile("新文件\n")
        await store.record(turn: 2, path: created, oldText: nil, newText: "新文件\n")
        #expect(await store.revert(path: created) == .reverted)
        #expect(!FileManager.default.fileExists(atPath: created))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("磁盘内容被他人修改后报告冲突且不覆盖")
    func conflict() async throws {
        let store = CheckpointStore()
        let path = try tempFile("agent 写入\n")
        await store.record(turn: 1, path: path, oldText: "原始\n", newText: "agent 写入\n")
        try "用户又改了\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await store.revert(path: path) == .conflict)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "用户又改了\n")
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("同一轮多次改动保留最初的原始内容")
    func firstOriginalWins() async throws {
        let store = CheckpointStore()
        let path = try tempFile("v3\n")
        await store.record(turn: 1, path: path, oldText: "v1\n", newText: "v2\n")
        await store.record(turn: 1, path: path, oldText: "v2\n", newText: "v3\n")
        #expect(await store.revert(path: path) == .reverted)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "v1\n")
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("按块回退写回磁盘")
    func hunkRevert() async throws {
        let store = CheckpointStore()
        let old = (1...30).map(String.init).joined(separator: "\n") + "\n"
        var lines = (1...30).map(String.init)
        lines[1] = "two"; lines[28] = "twenty-nine"
        let new = lines.joined(separator: "\n") + "\n"
        let path = try tempFile(new)
        await store.record(turn: 1, path: path, oldText: old, newText: new)
        #expect(await store.revert(path: path, hunks: [0]) == .reverted)
        let content = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(content[1] == "2" && content[28] == "twenty-nine")
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite("行内差异")
struct InlineDiffTests {
    @Test("去掉公共前后缀并扩展到词边界")
    func ranges() throws {
        let r = try #require(InlineDiff.changedRanges(old: "let value = computeTotal(items)", new: "let value = computeSum(items)"))
        let old = Array("let value = computeTotal(items)")
        let new = Array("let value = computeSum(items)")
        #expect(String(old[r.old]) == "computeTotal")
        #expect(String(new[r.new]) == "computeSum")
    }

    @Test("相同、差异过大或过长的行不做行内高亮")
    func skipped() {
        #expect(InlineDiff.changedRanges(old: "a", new: "a") == nil)
        #expect(InlineDiff.changedRanges(old: "completely different", new: "nothing alike here") == nil)
        #expect(InlineDiff.changedRanges(old: String(repeating: "a", count: 700), new: String(repeating: "b", count: 700)) == nil)
    }

    @Test("块内删除段与新增段按顺序配对")
    func pairing() {
        let lines = [
            DiffLine(kind: .context, text: "x", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .removed, text: "foo(1)", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .removed, text: "bar(2)", oldNumber: 3, newNumber: nil),
            DiffLine(kind: .added, text: "foo(10)", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .added, text: "bar(2)!", oldNumber: nil, newNumber: 3),
            DiffLine(kind: .added, text: "extra", oldNumber: nil, newNumber: 4),
        ]
        let marks = InlineDiff.highlights(for: lines)
        #expect(marks.count == 6)
        #expect(marks[0] == nil && marks[5] == nil)
        #expect(marks[1] != nil && marks[3] != nil && marks[2] != nil && marks[4] != nil)
    }
}
