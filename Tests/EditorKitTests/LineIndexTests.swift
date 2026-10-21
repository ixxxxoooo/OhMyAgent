// @author ixxxxoooo
// 行索引:基本查询、显示列数估算,以及增量更新与整体重建逐项一致(含随机编辑、换行/制表符/中日韩/代理对)。

import Foundation
import Testing
@testable import EditorKit

/// 固定种子的伪随机数(线性同余),保证测试可复现。
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("行索引")
struct LineIndexTests {
    @Test("基本查询:行起点、偏移转行号、行范围")
    func basics() {
        let index = LineIndex(text: "ab\ncde\n\nf")
        #expect(index.lineStarts == [0, 3, 7, 8])
        #expect(index.lineCount == 4)
        #expect(index.length == 9)
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 7) == 2)
        #expect(index.line(containing: 99) == 3)
        #expect(index.range(ofLine: 1) == NSRange(location: 3, length: 4))
        #expect(index.range(ofLine: 3) == NSRange(location: 8, length: 1))
        #expect(index.range(ofLine: 4) == nil)
    }

    @Test("空文本与末尾换行:恒有一行")
    func emptyAndTrailingNewline() {
        #expect(LineIndex(text: "").lineStarts == [0])
        #expect(LineIndex(text: "").longestColumns == 0)
        #expect(LineIndex(text: "a\n").lineStarts == [0, 2])
    }

    @Test("显示列数:制表符按 4 列,中日韩与表情按 2 列,UTF-16 偏移按单元计")
    func columns() {
        let index = LineIndex(text: "abc\n\tx\n中文\n😀a\n")
        #expect(index.lineColumns == [3, 5, 4, 3, 0])
        // 偏移单位是 UTF-16:「😀」占 2 个单元
        #expect(index.lineStarts == [0, 4, 7, 10, 14])
        #expect(index.length == "abc\n\tx\n中文\n😀a\n".utf16.count)
        #expect(index.longestColumns == 5)
        #expect(LineIndex(text: "\tx", tabColumns: 8).longestColumns == 9)
    }

    @Test("U+2E80 边界:之前按 1 列,之后按 2 列")
    func wideBoundary() {
        #expect(LineIndex(text: "\u{2E7F}").longestColumns == 1)
        #expect(LineIndex(text: "\u{2E80}").longestColumns == 2)
        #expect(LineIndex(text: "é").longestColumns == 1)
        #expect(LineIndex(text: "─").longestColumns == 1)   // U+2500 制表符号
    }

    @Test("增量更新:几个典型编辑与整体重建一致")
    func typicalEdits() {
        let base = "line one\nline two\n\tthree 中文\nfour"
        let cases: [(NSRange, String)] = [
            (NSRange(location: 0, length: 0), "x"),                       // 行首插入
            (NSRange(location: 8, length: 0), "\n"),                      // 行尾插入换行
            (NSRange(location: 8, length: 1), ""),                        // 删除换行,合并两行
            (NSRange(location: 5, length: 20), "A\nB\nC"),                // 跨行替换为多行
            (NSRange(location: 0, length: base.utf16.count), ""),         // 全删
            (NSRange(location: base.utf16.count, length: 0), "\n\n末尾"),  // 文末追加
            (NSRange(location: 9, length: 0), "😀\t"),                    // 代理对 + 制表符
        ]
        for (range, replacement) in cases {
            let storage = NSMutableString(string: base)
            var index = LineIndex(text: base)
            storage.replaceCharacters(in: range, with: replacement)
            let ok = index.applyEdit(editedRange: NSRange(location: range.location, length: replacement.utf16.count),
                                     changeInLength: replacement.utf16.count - range.length, text: storage)
            #expect(ok)
            #expect(index == LineIndex(text: storage as String), "编辑 \(range) → \(replacement.debugDescription)")
        }
    }

    @Test("增量更新:2000 次随机编辑后始终与整体重建一致")
    func randomEdits() {
        var generator = SeededGenerator(state: 42)
        let alphabet: [String] = ["a", "b", " ", "\n", "\n", "\t", "中", "😀", "é", "{", "\u{2E80}", "x"]
        var storage = NSMutableString(string: "hello\nworld\n\tindent 中文\n😀 emoji\nlast")
        var index = LineIndex(text: storage as String)
        for step in 0..<2_000 {
            let length = storage.length
            // 避免把代理对从中间劈开(真实编辑不会产生孤立代理项)
            var location = Int.random(in: 0...length, using: &generator)
            var removed = Int.random(in: 0...min(12, length - location), using: &generator)
            func isLow(_ position: Int) -> Bool { position < storage.length && (0xDC00...0xDFFF).contains(storage.character(at: position)) }
            if isLow(location) { location -= 1; removed += 1 }
            if isLow(location + removed) { removed += 1 }
            let pieceCount = Int.random(in: 0...4, using: &generator)
            let replacement = (0..<pieceCount).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }.joined()
            let range = NSRange(location: location, length: removed)
            storage.replaceCharacters(in: range, with: replacement)
            let ok = index.applyEdit(editedRange: NSRange(location: location, length: replacement.utf16.count),
                                     changeInLength: replacement.utf16.count - removed, text: storage)
            #expect(ok, "第 \(step) 步应用失败")
            guard index == LineIndex(text: storage as String) else {
                Issue.record("第 \(step) 步后与整体重建不一致:range=\(range) replacement=\(replacement.debugDescription)")
                return
            }
        }
        storage = NSMutableString()
    }

    @Test("增量更新:参数不自洽时拒绝并保持原状")
    func rejectsInconsistentEdit() {
        var index = LineIndex(text: "abc\ndef")
        let snapshot = index
        let text = NSString(string: "abc\ndef")
        let outOfRange = index.applyEdit(editedRange: NSRange(location: 50, length: 1), changeInLength: 1, text: text)
        let wrongLength = index.applyEdit(editedRange: NSRange(location: 0, length: 1), changeInLength: 5, text: text)   // 长度对不上
        #expect(!outOfRange && !wrongLength)
        #expect(index == snapshot)
    }

    @Test("增量更新:5 万行文件单次编辑远快于整体重建")
    func incrementalIsFast() {
        let text = (0..<50_000).map { "let value\($0) = \($0) // 注释" }.joined(separator: "\n")
        var index = LineIndex(text: text)
        let storage = NSMutableString(string: text)
        let clock = ContinuousClock()
        let rebuild = clock.measure { _ = LineIndex(text: text) }
        let location = storage.length / 2
        let incremental = clock.measure {
            for _ in 0..<100 {
                storage.insert("x", at: location)
                index.applyEdit(editedRange: NSRange(location: location, length: 1), changeInLength: 1, text: storage)
            }
        }
        #expect(index == LineIndex(text: storage as String))
        // 100 次增量编辑总耗时应小于 1 次整体重建的 5 倍(实际约低一个数量级;留足 CI 抖动余量)
        #expect(incremental < rebuild * 5, "增量 100 次 \(incremental) vs 重建 1 次 \(rebuild)")
    }
}
