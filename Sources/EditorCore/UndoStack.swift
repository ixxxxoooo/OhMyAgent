// @author ixxxxoooo
// 撤销栈:以不可变文本快照记录每个事务的前后状态(结构共享,几乎不额外占内存),
// 撤销/重做即 O(1) 切换快照;同时保留逐条编辑记录,供增量消费者(语法树、行索引、LSP)使用。

import Foundation

/// 一次已应用的原子替换:`location` 处 `oldLength` 个单元被替换为 `newLength` 个单元。
/// 多条编辑按「应用顺序」排列,每条的坐标相对其应用前的文本。
public struct AppliedEdit: Sendable, Hashable {
    public var location: Int
    public var oldLength: Int
    public var newLength: Int

    public init(location: Int, oldLength: Int, newLength: Int) {
        self.location = location
        self.oldLength = oldLength
        self.newLength = newLength
    }

    /// 逆编辑(撤销用)。
    public var inverted: AppliedEdit { AppliedEdit(location: location, oldLength: newLength, newLength: oldLength) }
}

/// 撤销事务。
struct UndoTransaction: Sendable {
    var id: Int
    var before: TextRope
    var after: TextRope
    var edits: [AppliedEdit]
    var selectionsBefore: [Selection]
    var selectionsAfter: [Selection]
    var coalesceKey: String?
    var time: TimeInterval
}

/// 撤销栈(值类型,由 `EditorDocument` 持有)。
struct UndoStack: Sendable {
    /// 事务栈上限,超出时丢弃最旧的。
    static let capacity = 2000
    /// 同键合并的时间窗口(秒)。
    static let coalesceWindow: TimeInterval = 0.8

    private(set) var undoStack: [UndoTransaction] = []
    private(set) var redoStack: [UndoTransaction] = []
    private var nextID = 1

    /// 当前栈顶事务 id(无事务为 0),用于脏状态比较。
    var topID: Int { undoStack.last?.id ?? 0 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 记录一次变更;若与上一事务同键且在窗口内则合并。
    mutating func record(
        before: TextRope, after: TextRope, edits: [AppliedEdit],
        selectionsBefore: [Selection], selectionsAfter: [Selection],
        coalesceKey: String?, time: TimeInterval
    ) {
        redoStack.removeAll(keepingCapacity: false)
        if let key = coalesceKey, var last = undoStack.last, last.coalesceKey == key,
           time - last.time <= UndoStack.coalesceWindow {
            last.after = after
            last.edits.append(contentsOf: edits)
            last.selectionsAfter = selectionsAfter
            last.time = time
            last.id = nextID
            nextID += 1
            undoStack[undoStack.count - 1] = last
            return
        }
        undoStack.append(UndoTransaction(
            id: nextID, before: before, after: after, edits: edits,
            selectionsBefore: selectionsBefore, selectionsAfter: selectionsAfter,
            coalesceKey: coalesceKey, time: time))
        nextID += 1
        if undoStack.count > UndoStack.capacity { undoStack.removeFirst(undoStack.count - UndoStack.capacity) }
    }

    /// 弹出一个待撤销事务(移入重做栈)。
    mutating func popUndo() -> UndoTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        redoStack.append(transaction)
        return transaction
    }

    /// 弹出一个待重做事务(移回撤销栈)。
    mutating func popRedo() -> UndoTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        undoStack.append(transaction)
        return transaction
    }

    /// 清空历史。
    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// 打断合并:下一次编辑一定开新事务(光标跳转、保存等场景调用)。
    mutating func breakCoalescing() {
        guard !undoStack.isEmpty else { return }
        undoStack[undoStack.count - 1].coalesceKey = nil
    }
}
