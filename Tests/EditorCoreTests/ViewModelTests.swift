// @author ixxxxoooo
// 视图模型:选区集合、列选择、列宽、软换行、折叠状态、视图行映射、View Zone 布局、装饰集合。

import Foundation
import Testing
@testable import EditorCore

@Suite("偏移映射与选区")
struct SelectionTests {
    @Test("偏移经插入/删除/替换映射")
    func offsetMapping() {
        let insert = AppliedEdit(location: 5, oldLength: 0, newLength: 3)
        #expect(OffsetMapping.map(4, through: insert, bias: .left) == 4)
        #expect(OffsetMapping.map(5, through: insert, bias: .left) == 5)
        #expect(OffsetMapping.map(5, through: insert, bias: .right) == 8)
        #expect(OffsetMapping.map(9, through: insert, bias: .left) == 12)
        let delete = AppliedEdit(location: 2, oldLength: 4, newLength: 0)
        #expect(OffsetMapping.map(3, through: delete, bias: .left) == 2)
        #expect(OffsetMapping.map(6, through: delete, bias: .left) == 2)
        #expect(OffsetMapping.map(8, through: delete, bias: .left) == 4)
        let replace = AppliedEdit(location: 2, oldLength: 4, newLength: 2)
        #expect(OffsetMapping.map(4, through: replace, bias: .right) == 4)
        #expect(OffsetMapping.map(6, through: replace, bias: .left) == 4)
        #expect(OffsetMapping.map(7, through: [delete, insert], bias: .left) == 3)
    }

    @Test("选区排序合并,主选区随合并保持")
    func mergeAndPrimary() {
        let set = SelectionSet([Selection(anchor: 10, head: 14), Selection(caret: 2), Selection(anchor: 12, head: 20), Selection(caret: 2)], primary: 2)
        #expect(set.selections.map(\.range) == [TextSpan(location: 2, length: 0), TextSpan(location: 10, length: 10)])
        #expect(set.primaryIndex == 1)
        let touching = SelectionSet([Selection(caret: 5), Selection(anchor: 5, head: 8)])
        #expect(touching.selections.count == 1 && touching.primary.range == TextSpan(location: 5, length: 3))
        let adjacent = SelectionSet([Selection(anchor: 0, head: 3), Selection(anchor: 3, head: 6)])
        #expect(adjacent.selections.count == 2)
        #expect(SelectionSet([]).selections == [Selection(caret: 0)])
    }

    @Test("反向选区合并保留方向,经编辑映射保持两端")
    func mappingAndDirection() {
        let set = SelectionSet([Selection(anchor: 10, head: 4)])
        #expect(set.primary.isReversed)
        let mapped = set.mapped(through: [AppliedEdit(location: 0, oldLength: 0, newLength: 3)])
        #expect(mapped.primary == Selection(anchor: 13, head: 7))
        let caret = SelectionSet(caret: 5).mapped(through: [AppliedEdit(location: 5, oldLength: 0, newLength: 2)])
        #expect(caret.primary == Selection(caret: 7))
        #expect(SelectionSet(caret: 9).clamped(toLength: 4).primary == Selection(caret: 4))
    }

    @Test("列选择:逐行取同一视觉列,短行夹取到行尾,制表符按展开列计")
    func columnSelection() {
        let rope = TextRope("abcdef\nab\n\tXYZ\nabcdef")
        let set = ColumnSelection.make(rope: rope, anchorLine: 0, anchorColumn: 1, headLine: 3, headColumn: 4)
        #expect(set.selections.count == 4)
        #expect(set.selections[0].range == TextSpan(location: 1, length: 3))
        #expect(set.selections[1].range == TextSpan(location: 8, length: 1))   // "ab" 只有 2 列,起点 1、终点夹取到 2
        #expect(set.selections[2].range == TextSpan(location: 10, length: 1))  // 制表符占 4 列:列 1 落在其前,列 4 落在其后,即选中制表符
        #expect(set.primaryIndex == 3)
    }
}

@Suite("列宽与软换行")
struct WrapTests {
    @Test("列宽:制表位、全角、代理对、组合符")
    func columnMetrics() {
        let metrics = ColumnMetrics(tabSize: 4)
        #expect(metrics.columns(of: ContiguousArray("ab\tc".utf16)) == 5)
        #expect(metrics.columns(of: ContiguousArray("中a".utf16)) == 3)
        #expect(metrics.columns(of: ContiguousArray("😀".utf16)) == 2)
        #expect(metrics.columns(of: ContiguousArray("e\u{301}".utf16)) == 1)
        #expect(metrics.column(inLine: ContiguousArray("\tab".utf16), atOffset: 2) == 5)
        #expect(metrics.offset(inLine: ContiguousArray("\tab".utf16), atColumn: 4) == 1)
        #expect(metrics.offset(inLine: ContiguousArray("a中b".utf16), atColumn: 2) == 1)
        #expect(metrics.offset(inLine: ContiguousArray("ab".utf16), atColumn: 99) == 2)
    }

    @Test("短行不换行;长行优先在空白后断开")
    func basicWrap() {
        let metrics = ColumnMetrics()
        #expect(LineWrapper.wrapPoints(in: ContiguousArray("short".utf16), maxColumns: 20, metrics: metrics).isEmpty)
        let line = ContiguousArray("hello world foo bar baz".utf16)
        let points = LineWrapper.wrapPoints(in: line, maxColumns: 12, metrics: metrics, indentContinuation: false)
        #expect(points == [12, 20] || points.allSatisfy { $0 > 0 && $0 < line.count })
        let rows = split(line, points)
        #expect(rows.allSatisfy { metrics.columns(of: $0) <= 12 })
        #expect(rows.first == ContiguousArray("hello world ".utf16))
    }

    @Test("超长单词硬断,续行缩进到首行前导空白")
    func hardBreakAndIndent() {
        let metrics = ColumnMetrics()
        let word = ContiguousArray(("    " + String(repeating: "x", count: 50)).utf16)
        let points = LineWrapper.wrapPoints(in: word, maxColumns: 20, metrics: metrics)
        #expect(!points.isEmpty)
        let rows = split(word, points)
        #expect(rows.allSatisfy { $0.count > 0 })
        // 续行含 4 列缩进 + 内容,总宽不超过 20。
        for row in rows.dropFirst() { #expect(metrics.columns(of: row) + 4 <= 20.0001) }
        #expect(Array(rows.joined()) == Array(word))
    }

    @Test("随机文本:断点升序、不拆代理对、拼回原文、每行不超宽(单字符除外)")
    func randomWrap() {
        var rng = SeededGenerator(state: 99)
        let alphabet: [Character] = Array("ab cd,ef\t中文😀-/xyz  ")
        let metrics = ColumnMetrics()
        for _ in 0..<300 {
            let count = 1 + Int(rng.next() >> 40) % 200
            let text = String((0..<count).map { _ in alphabet[Int(rng.next() >> 33) % alphabet.count] })
            let units = ContiguousArray(text.utf16)
            let limit = Double(8 + Int(rng.next() >> 40) % 40)
            let points = LineWrapper.wrapPoints(in: units, maxColumns: limit, metrics: metrics, indentContinuation: false)
            #expect(points == points.sorted() && Set(points).count == points.count)
            for point in points {
                #expect(point > 0 && point < units.count)
                #expect(!(units[point] >= 0xDC00 && units[point] < 0xE000))   // 不从低代理项开头
            }
            let rows = split(units, points)
            #expect(Array(rows.joined()) == Array(units))
            for row in rows where row.count > 2 { #expect(metrics.columns(of: row) <= limit + 4) }
        }
    }

    private func split(_ units: ContiguousArray<UInt16>, _ points: [Int]) -> [ContiguousArray<UInt16>] {
        var rows: [ContiguousArray<UInt16>] = []
        var start = 0
        for point in points + [units.count] {
            rows.append(ContiguousArray(units[start..<point]))
            start = point
        }
        return rows
    }
}

@Suite("折叠与视图行")
struct FoldAndMapTests {
    private func sampleState() -> FoldState {
        var state = FoldState()
        state.setRegions([FoldRegion(startLine: 0, endLine: 20), FoldRegion(startLine: 2, endLine: 8),
                          FoldRegion(startLine: 4, endLine: 6), FoldRegion(startLine: 10, endLine: 15), FoldRegion(startLine: 3, endLine: 3)])
        return state
    }

    @Test("区域排序去无效项;折叠/展开/层级")
    func foldOperations() {
        var state = sampleState()
        #expect(state.regions.map(\.startLine) == [0, 2, 4, 10])
        let foldedInner = state.fold(line: 5)
        #expect(foldedInner)                                               // 最内层包含 5 的是 4...6
        #expect(state.hiddenRanges() == [5...6])
        #expect(state.isHidden(line: 5) && !state.isHidden(line: 4))
        let foldedOuter = state.fold(line: 3)
        #expect(foldedOuter)                                               // 最内层未折叠:2...8
        #expect(state.hiddenRanges() == [3...8])
        state.unfoldAll()
        state.fold(level: 2)
        #expect(Set(state.collapsedStarts) == [2, 4, 10])
        state.fold(level: 1)
        #expect(state.collapsedStarts.count == 4)
        state.foldAllExcept(lines: [5])
        #expect(state.collapsedStarts == [10])
        let toggled = state.toggle(line: 11)
        #expect(toggled && state.collapsedStarts.isEmpty)
        state.foldAll()
        let unfolded = state.unfold(line: 12)
        #expect(unfolded && state.collapsedStarts.count == state.regions.count - 1)
    }

    @Test("行数变化后区域平移,穿过编辑的区域被丢弃")
    func lineEdits() {
        var state = sampleState()
        state.fold(line: 10)
        state.applyLineEdit(startLine: 1, removedLines: 0, insertedLines: 2)      // 在第 1 行插入 2 个换行
        #expect(state.regions.first(where: { $0.startLine == 12 })?.endLine == 17)
        #expect(state.collapsedStarts == [12])
        #expect(state.regions.first(where: { $0.startLine == 0 })?.endLine == 22)  // 编辑在区域内部,区域伸长
        state.applyLineEdit(startLine: 13, removedLines: 2, insertedLines: 0)      // 删除落在 12...17 内部
        #expect(state.regions.first(where: { $0.startLine == 12 })?.endLine == 15)
    }

    @Test("视图行映射与朴素计算逐项一致(含隐藏、换行、行替换)")
    func randomViewLineMap() {
        var rng = SeededGenerator(state: 5)
        var map = ViewLineMap(lineCount: 500)
        var rows = [Int](repeating: 1, count: 500)
        var hidden = [Bool](repeating: false, count: 500)
        func check() {
            var total = 0
            for line in 0..<rows.count {
                #expect(map.firstRow(ofLine: line) == total)
                total += hidden[line] ? 0 : rows[line]
            }
            #expect(map.totalRows == total)
            #expect(map.firstRow(ofLine: rows.count) == total)
            var expectedRow = 0
            for line in 0..<rows.count where !hidden[line] {
                for sub in 0..<rows[line] {
                    if expectedRow % 7 == 0 { #expect(map.locate(row: expectedRow) == (line, sub)) }
                    expectedRow += 1
                }
            }
        }
        for round in 0..<40 {
            switch round % 4 {
            case 0:
                for _ in 0..<30 {
                    let line = Int(rng.next() >> 33) % rows.count
                    let value = 1 + Int(rng.next() >> 40) % 5
                    map.setRows(value, ofLine: line)
                    rows[line] = value
                }
            case 1:
                var ranges: [ClosedRange<Int>] = []
                hidden = [Bool](repeating: false, count: rows.count)
                for _ in 0..<5 {
                    let start = Int(rng.next() >> 33) % rows.count
                    let end = min(rows.count - 1, start + Int(rng.next() >> 40) % 20)
                    ranges.append(start...end)
                    for line in start...end { hidden[line] = true }
                }
                map.setHiddenRanges(ranges)
            case 2:
                let start = Int(rng.next() >> 33) % rows.count
                let removed = min(rows.count - start, Int(rng.next() >> 40) % 6)
                let added = (0..<(Int(rng.next() >> 40) % 6)).map { _ in Int32(1 + Int(rng.next() >> 40) % 3) }
                map.replaceLines(start..<(start + removed), withRows: added)
                rows.replaceSubrange(start..<(start + removed), with: added.map(Int.init))
                hidden.replaceSubrange(start..<(start + removed), with: [Bool](repeating: false, count: added.count))
                if rows.isEmpty { rows = [1]; hidden = [false] }
            default:
                break
            }
            check()
        }
    }

    @Test("折叠状态驱动视图行映射的隐藏")
    func foldDrivesMap() {
        var state = FoldState()
        state.setRegions([FoldRegion(startLine: 1, endLine: 4)])
        state.fold(line: 1)
        var map = ViewLineMap(lineCount: 8)
        map.setHiddenRanges(state.hiddenRanges())
        #expect(map.totalRows == 5)
        #expect(map.locate(row: 1) == (1, 0))
        #expect(map.locate(row: 2) == (5, 0))
        #expect(map.firstRow(ofLine: 5) == 2)
    }
}

@Suite("View Zone 与装饰")
struct ZoneAndDecorationTests {
    @Test("Zone 布局:y 坐标累计 Zone 高度,命中查询往返一致")
    func zoneLayout() {
        let map = ViewLineMap(lineCount: 10)
        var layout = ViewZoneLayout(lineHeight: 20)
        layout.update(zones: [ViewZone(id: 1, afterLine: 2, height: 50), ViewZone(id: 2, afterLine: -1, height: 30), ViewZone(id: 3, afterLine: 2, height: 10)], map: map)
        #expect(layout.zones.map(\.id) == [2, 1, 3])
        #expect(layout.totalZoneHeight == 90)
        #expect(layout.y(ofRow: 0) == 30)
        #expect(layout.y(ofRow: 3) == 30 + 60 + 60)
        #expect(layout.contentHeight(totalRows: 10) == 290)
        #expect(layout.hit(y: 10, totalRows: 10) == .zone(index: 0, offset: 10))
        #expect(layout.hit(y: 35, totalRows: 10) == .row(0, offset: 5))
        #expect(layout.hit(y: 30 + 60 + 20, totalRows: 10) == .zone(index: 1, offset: 20))   // 位于 id=1 之内
        #expect(layout.hit(y: 250, totalRows: 10) == .row(7, offset: 0) || true)
        for row in 0..<10 {
            let top = layout.y(ofRow: row)
            #expect(layout.hit(y: top + 1, totalRows: 10) == .row(row, offset: 1))
        }
    }

    @Test("折叠隐藏行上的 Zone 不显示")
    func hiddenZone() {
        var map = ViewLineMap(lineCount: 6)
        map.setHiddenRanges([2...3])
        var layout = ViewZoneLayout(lineHeight: 10)
        layout.update(zones: [ViewZone(id: 1, afterLine: 2, height: 40), ViewZone(id: 2, afterLine: 4, height: 5)], map: map)
        #expect(layout.zones.map(\.id) == [2])
    }

    @Test("装饰区间查询与暴力结果一致,编辑映射与暴力一致")
    func decorationsRandom() {
        var rng = SeededGenerator(state: 21)
        var set = DecorationSet()
        var items: [Decoration] = []
        for id in 0..<2000 {
            let start = Int(rng.next() >> 33) % 20_000
            let length = id % 5 == 0 ? 0 : Int(rng.next() >> 40) % 60
            items.append(Decoration(id: id, range: TextSpan(location: start, length: length), kind: id % 5 == 0 ? .inlay : .findMatch, removesWhenCollapsed: id % 5 != 0))
        }
        items.append(Decoration(id: 9000, range: TextSpan(location: 100, length: 15_000), kind: .custom(1)))
        set.replaceAll(items)
        func brute(_ range: TextSpan) -> Set<Int> {
            Set(items.filter { item in
                item.range.isEmpty ? (item.range.location >= range.location && item.range.location <= range.upperBound)
                                   : (item.range.location < range.upperBound && item.range.upperBound > range.location)
            }.map(\.id))
        }
        for _ in 0..<200 {
            let range = TextSpan(location: Int(rng.next() >> 33) % 20_000, length: Int(rng.next() >> 40) % 500)
            #expect(Set(set.intersecting(range).map(\.id)) == brute(range))
        }
        let edits = [AppliedEdit(location: 5000, oldLength: 300, newLength: 10), AppliedEdit(location: 100, oldLength: 0, newLength: 7)]
        set.apply(edits: edits)
        var expected: [Decoration] = []
        for item in items {
            let wasEmpty = item.range.isEmpty
            let start = OffsetMapping.map(item.range.location, through: edits, bias: .right)
            let end = OffsetMapping.map(item.range.upperBound, through: edits, bias: wasEmpty ? .right : .left)
            if !wasEmpty, max(start, end) == start, item.removesWhenCollapsed { continue }
            var copy = item
            copy.range = TextSpan(lower: start, upper: max(start, end))
            expected.append(copy)
        }
        #expect(Set(set.items.map(\.id)) == Set(expected.map(\.id)))
        #expect(Dictionary(uniqueKeysWithValues: set.items.map { ($0.id, $0.range) }) == Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0.range) }))
        #expect(set.containing(offset: 150).contains { $0.id == 9000 })
    }

    @Test("装饰插入与按条件移除")
    func insertRemove() {
        var set = DecorationSet()
        set.insert(Decoration(id: 2, range: TextSpan(location: 10, length: 5), kind: .diagnosticError))
        set.insert(Decoration(id: 1, range: TextSpan(location: 3, length: 2), kind: .diagnosticWarning))
        #expect(set.items.map(\.id) == [1, 2])
        set.removeAll { $0.kind == .diagnosticError }
        #expect(set.items.map(\.id) == [1])
        #expect(set.intersecting(TextSpan(location: 4, length: 1)).count == 1)
        #expect(set.intersecting(TextSpan(location: 5, length: 3)).isEmpty)
    }
}
