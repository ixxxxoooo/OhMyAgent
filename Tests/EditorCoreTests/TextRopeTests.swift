// @author ixxxxoooo
// 文本绳:与朴素数组模型的随机对照(增删、行定位、切片、快照不可变),以及大文本与边界场景。

import Foundation
import Testing
@testable import EditorCore

/// 固定种子的伪随机数,保证测试可复现。
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// 朴素参照模型:直接用 `[UInt16]` 实现同样的行查询。
struct NaiveText {
    var units: [UInt16] = []

    var lineCount: Int { units.filter { $0 == 10 }.count + 1 }

    func lineStart(_ line: Int) -> Int {
        if line <= 0 { return 0 }
        var seen = 0
        for (index, unit) in units.enumerated() where unit == 10 {
            seen += 1
            if seen == line { return index + 1 }
        }
        return units.count
    }

    func line(containing offset: Int) -> Int {
        let clamped = min(max(offset, 0), units.count)
        return units[0..<clamped].filter { $0 == 10 }.count
    }
}

/// 生成随机文本:字母、换行、少量代理对。
func randomUnits(count: Int, using rng: inout SeededGenerator) -> ContiguousArray<UInt16> {
    var result = ContiguousArray<UInt16>()
    result.reserveCapacity(count)
    let alphabet: [UInt16] = Array("abcdefg \n\n\t{}中".utf16)
    for _ in 0..<count {
        result.append(alphabet[Int(rng.next() >> 33) % alphabet.count])
    }
    return result
}

@Suite("文本绳")
struct TextRopeTests {
    @Test("空文本与基本查询")
    func basics() {
        let rope = TextRope("ab\ncde\n\nf")
        #expect(rope.length == 9)
        #expect(rope.lineCount == 4)
        #expect(rope.lineStart(0) == 0)
        #expect(rope.lineStart(1) == 3)
        #expect(rope.lineStart(2) == 7)
        #expect(rope.lineStart(3) == 8)
        #expect(rope.lineStart(4) == 9)
        #expect(rope.lineRange(1) == TextSpan(location: 3, length: 3))
        #expect(rope.lineRange(2) == TextSpan(location: 7, length: 0))
        #expect(rope.lineRange(4) == nil)
        #expect(rope.line(containing: 3) == 1)
        #expect(rope.line(containing: 2) == 0)
        #expect(rope.line(containing: 999) == 3)
        #expect(rope.position(at: 5) == TextPosition(line: 1, column: 2))
        #expect(rope.offset(of: TextPosition(line: 1, column: 99)) == 6)
        #expect(rope.lineText(1) == "cde")
        let empty = TextRope()
        #expect(empty.length == 0 && empty.lineCount == 1 && empty.lineRange(0) == TextSpan(location: 0, length: 0))
    }

    @Test("随机增删与朴素模型逐项一致(内容、行数、行起点、行号)")
    func randomOperations() {
        var rng = SeededGenerator(state: 42)
        var rope = TextRope()
        var model = NaiveText()
        for step in 0..<1500 {
            let roll = Int(rng.next() >> 40) % 10
            if roll < 6 || model.units.isEmpty {
                let at = Int(rng.next() >> 33) % (model.units.count + 1)
                let size = roll == 0 ? 1 + Int(rng.next() >> 33) % 6000 : 1 + Int(rng.next() >> 33) % 40
                let text = randomUnits(count: size, using: &rng)
                rope = rope.inserting(text, at: at)
                model.units.insert(contentsOf: text, at: at)
            } else {
                let at = Int(rng.next() >> 33) % model.units.count
                let size = 1 + Int(rng.next() >> 33) % (roll == 9 ? 5000 : 30)
                let range = TextSpan(location: at, length: min(size, model.units.count - at))
                rope = rope.deleting(range)
                model.units.removeSubrange(range.location..<range.upperBound)
            }
            #expect(rope.length == model.units.count)
            if step % 100 == 0 {
                #expect(Array(rope.slice(TextSpan(location: 0, length: rope.length))) == model.units)
                #expect(rope.lineCount == model.lineCount)
                for line in stride(from: 0, to: model.lineCount + 1, by: max(1, model.lineCount / 17)) {
                    #expect(rope.lineStart(line) == model.lineStart(line))
                }
                for _ in 0..<20 {
                    let offset = Int(rng.next() >> 33) % (model.units.count + 1)
                    #expect(rope.line(containing: offset) == model.line(containing: offset))
                    if offset < model.units.count { #expect(rope.unit(at: offset) == model.units[offset]) }
                }
            }
        }
        #expect(Array(rope.slice(TextSpan(location: 0, length: rope.length))) == model.units)
    }

    @Test("随机区间切片与分块遍历一致")
    func slicing() {
        var rng = SeededGenerator(state: 7)
        let text = randomUnits(count: 30_000, using: &rng)
        let rope = TextRope(utf16: text)
        for _ in 0..<200 {
            let location = Int(rng.next() >> 33) % (text.count + 1)
            let length = Int(rng.next() >> 33) % 5000
            let range = TextSpan(location: location, length: length)
            let upper = min(range.upperBound, text.count)
            #expect(Array(rope.slice(range)) == Array(text[location..<max(location, upper)]))
        }
    }

    @Test("快照不可变:后续编辑不影响旧快照")
    func snapshotsAreImmutable() {
        let first = TextRope("hello\nworld")
        let second = first.replacing(TextSpan(location: 0, length: 5), with: ContiguousArray("HELLO!!".utf16))
        #expect(first.string() == "hello\nworld")
        #expect(second.string() == "HELLO!!\nworld")
        let third = second.deleting(TextSpan(location: 0, length: 8))
        #expect(second.string() == "HELLO!!\nworld")
        #expect(third.string() == "world")
    }

    @Test("越界编辑被夹取而不崩溃")
    func clampsOutOfBounds() {
        let rope = TextRope("abc")
        #expect(rope.inserting(ContiguousArray("X".utf16), at: 99).string() == "abcX")
        #expect(rope.deleting(TextSpan(location: 2, length: 99)).string() == "ab")
        #expect(rope.deleting(TextSpan(location: 50, length: 3)).string() == "abc")
        #expect(rope.unit(at: -1) == nil && rope.unit(at: 3) == nil)
    }

    @Test("大文本:10MB 构建、整段替换与行定位")
    func largeText() {
        let line = "let value = computeSomething(argument: 42) // 注释\n"
        let repeated = String(repeating: line, count: 200_000)
        let rope = TextRope(repeated)
        #expect(rope.lineCount == 200_001)
        let units = line.utf16.count
        #expect(rope.lineStart(100_000) == 100_000 * units)
        #expect(rope.line(containing: 123_456 * units + 3) == 123_456)
        let replaced = rope.replacing(TextSpan(location: 0, length: rope.length), with: ContiguousArray("x\ny".utf16))
        #expect(replaced.string() == "x\ny" && replaced.lineCount == 2)
        #expect(rope.lineCount == 200_001)
    }

    @Test("大量单字符输入后树保持平衡,按行定位仍高效")
    func manySmallInserts() {
        var rope = TextRope()
        for index in 0..<20_000 {
            rope = rope.inserting(ContiguousArray(((index % 40 == 39) ? "\n" : "a").utf16), at: rope.length)
        }
        #expect(rope.length == 20_000)
        #expect(rope.lineCount == 501)
        #expect(rope.root.height <= 4)
    }
}

@Suite("换行归一")
struct LineEndingTests {
    @Test("CRLF 与孤立 CR 归一为 LF 并识别多数风格")
    func normalize() {
        let crlf = LineEnding.normalize(ContiguousArray("a\r\nb\r\nc".utf16))
        #expect(String(decoding: crlf.units, as: UTF16.self) == "a\nb\nc")
        #expect(crlf.dominant == .crlf && !crlf.isMixed)
        let cr = LineEnding.normalize(ContiguousArray("a\rb\rc".utf16))
        #expect(cr.dominant == .cr)
        let mixed = LineEnding.normalize(ContiguousArray("a\r\nb\nc\r\n".utf16))
        #expect(mixed.dominant == .crlf && mixed.isMixed)
        #expect(String(decoding: mixed.units, as: UTF16.self) == "a\nb\nc\n")
        let none = LineEnding.normalize(ContiguousArray("abc".utf16))
        #expect(none.dominant == .lf && !none.isMixed)
    }
}
