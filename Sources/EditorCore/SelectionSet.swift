// @author ixxxxoooo
// 选区集合:多光标、主选区、重叠合并、经编辑映射,以及列(块)选择的生成。

import Foundation

/// 多选区集合。不变量:按位置升序、互不重叠、至少一个选区、主选区下标有效。
public struct SelectionSet: Sendable, Equatable {
    /// 升序且互不重叠的选区。
    public private(set) var selections: [Selection]
    /// 主选区下标(滚动、状态栏与单光标操作以它为准)。
    public private(set) var primaryIndex: Int

    /// 由任意选区列表创建(会排序并合并重叠项)。
    /// - Parameters:
    ///   - selections: 选区列表,为空则放一个文首光标
    ///   - primary: 主选区在传入列表中的下标(默认最后一个,与 VS Code 一致)
    public init(_ selections: [Selection], primary: Int? = nil) {
        let input = selections.isEmpty ? [Selection(caret: 0)] : selections
        let primaryInput = min(max(primary ?? (input.count - 1), 0), input.count - 1)
        let merged = SelectionSet.merge(input, primary: primaryInput)
        self.selections = merged.selections
        self.primaryIndex = merged.primary
    }

    /// 单个光标。
    public init(caret: Int) { self.init([Selection(caret: caret)]) }

    /// 主选区。
    public var primary: Selection { selections[primaryIndex] }
    /// 是否多光标。
    public var isMulti: Bool { selections.count > 1 }

    /// 追加一个选区(默认设为主选区)。
    public func adding(_ selection: Selection, makePrimary: Bool = true) -> SelectionSet {
        var list = selections
        list.append(selection)
        return SelectionSet(list, primary: makePrimary ? list.count - 1 : primaryIndex)
    }

    /// 只保留主选区。
    public func collapsedToPrimary() -> SelectionSet { SelectionSet([primary]) }

    /// 按顺序映射每个选区的两端(空选区偏向右,保持在新插入文本之后)。
    public func mapped(through edits: [AppliedEdit]) -> SelectionSet {
        let mappedList = selections.map { selection -> Selection in
            let empty = selection.isEmpty
            let anchor = OffsetMapping.map(selection.anchor, through: edits, bias: empty || selection.anchor > selection.head ? .right : .left)
            let head = OffsetMapping.map(selection.head, through: edits, bias: empty || selection.head > selection.anchor ? .right : .left)
            return Selection(anchor: anchor, head: head)
        }
        return SelectionSet(mappedList, primary: primaryIndex)
    }

    /// 夹取到 `0...length`。
    public func clamped(toLength length: Int) -> SelectionSet {
        SelectionSet(selections.map { Selection(anchor: min($0.anchor, length), head: min($0.head, length)) }, primary: primaryIndex)
    }

    /// 排序并合并重叠或贴边(其中一方为空)的选区;返回合并后列表与主选区新下标。
    private static func merge(_ input: [Selection], primary: Int) -> (selections: [Selection], primary: Int) {
        let indexed = input.enumerated().sorted {
            let lhs = $0.element.range, rhs = $1.element.range
            return lhs.location != rhs.location ? lhs.location < rhs.location : lhs.length < rhs.length
        }
        var result: [Selection] = []
        var primaryResult = 0
        for (originalIndex, selection) in indexed {
            if var last = result.last {
                let lastRange = last.range
                let range = selection.range
                let touching = range.location == lastRange.upperBound && (lastRange.isEmpty || range.isEmpty)
                if range.location < lastRange.upperBound || touching {
                    let union = TextSpan(lower: lastRange.location, upper: max(lastRange.upperBound, range.upperBound))
                    last = last.isReversed ? Selection(anchor: union.upperBound, head: union.location)
                                           : Selection(anchor: union.location, head: union.upperBound)
                    result[result.count - 1] = last
                    if originalIndex == primary { primaryResult = result.count - 1 }
                    continue
                }
            }
            result.append(selection)
            if originalIndex == primary { primaryResult = result.count - 1 }
        }
        return (result, primaryResult)
    }
}

/// 列(块)选择:按视觉列在每一行生成一个选区,行太短时夹取到行尾。
public enum ColumnSelection {
    /// 生成列选择。
    /// - Parameters:
    ///   - rope: 文本快照
    ///   - anchorLine: 起始行
    ///   - anchorColumn: 起始视觉列(制表符展开后的列,可为小数)
    ///   - headLine: 当前行
    ///   - headColumn: 当前视觉列
    ///   - metrics: 列宽规则
    /// - Returns: 每行一个选区,主选区为光标所在行
    public static func make(
        rope: TextRope, anchorLine: Int, anchorColumn: Double, headLine: Int, headColumn: Double,
        metrics: ColumnMetrics = ColumnMetrics()
    ) -> SelectionSet {
        let lineCount = rope.lineCount
        let first = min(max(min(anchorLine, headLine), 0), lineCount - 1)
        let last = min(max(max(anchorLine, headLine), 0), lineCount - 1)
        var list: [Selection] = []
        list.reserveCapacity(last - first + 1)
        for line in first...last {
            guard let range = rope.lineRange(line) else { continue }
            let units = rope.slice(range)
            let anchor = range.location + metrics.offset(inLine: units, atColumn: anchorColumn)
            let head = range.location + metrics.offset(inLine: units, atColumn: headColumn)
            list.append(Selection(anchor: anchor, head: head))
        }
        let primary = max(0, min(list.count - 1, headLine - first))
        return SelectionSet(list, primary: headLine >= anchorLine ? list.count - 1 : 0).withPrimary(primary)
    }
}

extension SelectionSet {
    /// 指定主选区下标(越界夹取)。
    fileprivate func withPrimary(_ index: Int) -> SelectionSet {
        var copy = self
        copy.primaryIndex = min(max(index, 0), selections.count - 1)
        return copy
    }
}
