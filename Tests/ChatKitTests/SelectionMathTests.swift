// @author ixxxxoooo
// 跨文本块选择的纯计算:范围划分与复制文本拼接。

import Foundation
import Testing

@testable import ChatKit

@Suite("跨块选择计算")
struct SelectionMathTests {
    private func point(_ atom: Int, _ offset: Int) -> SelectionPoint { SelectionPoint(atom: atom, offset: offset) }

    @Test("同一原子内取两点之间,反向拖动结果相同")
    func sameAtom() {
        let forward = SelectionMath.ranges(lengths: [10], anchor: point(0, 2), focus: point(0, 7))
        let backward = SelectionMath.ranges(lengths: [10], anchor: point(0, 7), focus: point(0, 2))
        #expect(forward == [2..<7])
        #expect(backward == forward)
    }

    @Test("跨原子:起点原子取尾部,终点原子取头部,中间整段")
    func acrossAtoms() {
        let ranges = SelectionMath.ranges(lengths: [10, 5, 8, 6], anchor: point(0, 4), focus: point(3, 2))
        #expect(ranges == [4..<10, 0..<5, 0..<8, 0..<2])
    }

    @Test("起点在原子末尾 / 终点在原子开头:这些原子不算选中")
    func boundariesExcludeEmptyPieces() {
        let ranges = SelectionMath.ranges(lengths: [10, 5, 8], anchor: point(0, 10), focus: point(2, 0))
        #expect(ranges == [nil, 0..<5, nil])
    }

    @Test("两点相同为空选择;超出范围的偏移被夹住")
    func emptyAndClamped() {
        #expect(SelectionMath.ranges(lengths: [4, 4], anchor: point(1, 2), focus: point(1, 2)) == [nil, nil])
        #expect(SelectionMath.ranges(lengths: [4, 4], anchor: point(0, -5), focus: point(1, 99)) == [0..<4, 0..<4])
        #expect(SelectionMath.ranges(lengths: [], anchor: point(0, 0), focus: point(0, 1)).isEmpty)
    }

    @Test("长度为 0 的原子不产生范围")
    func zeroLengthAtom() {
        let ranges = SelectionMath.ranges(lengths: [3, 0, 3], anchor: point(0, 0), focus: point(2, 3))
        #expect(ranges == [0..<3, nil, 0..<3])
    }

    @Test("拼接:原子之间空一行;同行并排的两段只换行;只含选中的片段")
    func joinedText() {
        let texts = ["第一段文字", "代码\n保留换行", "左", "右"]
        let ranges: [Range<Int>?] = [2..<5, 0..<7, 0..<1, 0..<1]
        let text = SelectionMath.joined(texts: texts, ranges: ranges, sameRowAsPrevious: [false, false, false, true])
        #expect(text == "段文字\n\n代码\n保留换行\n\n左\n右")
    }

    @Test("拼接:没有选中任何内容为空串;未选中的原子被跳过")
    func joinedEmptyAndSkipped() {
        #expect(SelectionMath.joined(texts: ["甲", "乙"], ranges: [nil, nil], sameRowAsPrevious: [false, false]).isEmpty)
        #expect(SelectionMath.joined(texts: ["甲", "乙", "丙"], ranges: [0..<1, nil, 0..<1], sameRowAsPrevious: [false, false, false]) == "甲\n\n丙")
    }

    @Test("偏移按 UTF-16 计:emoji 占两个单位")
    func utf16Offsets() {
        let text = SelectionMath.joined(texts: ["a😀b"], ranges: [1..<3], sameRowAsPrevious: [false])
        #expect(text == "😀")
    }

    @Test("选择点按原子序号、偏移比较")
    func pointOrdering() {
        #expect(point(0, 9) < point(1, 0))
        #expect(point(2, 1) < point(2, 3))
        #expect(SelectionMath.ordered(point(3, 0), point(1, 5)).start == point(1, 5))
    }
}
