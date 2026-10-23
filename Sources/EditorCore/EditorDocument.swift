// @author ixxxxoooo
// 编辑文档:文本缓冲 + 撤销栈 + 变更通知。同一路径的多个标签/窗口共享同一份文档(见 `EditorDocumentRegistry`),
// 因此撤销历史、脏状态与内容天然一致。文档只在主线程变更;后台任务通过 `snapshot` 读取不可变快照。

import Foundation

/// 变更来源。
public enum ChangeOrigin: Sendable {
    /// 用户输入或编辑命令。
    case user
    /// 撤销。
    case undo
    /// 重做。
    case redo
    /// 磁盘外部改动、Agent 写盘等。
    case external
}

/// 一次文档变更的描述,发给观察者。
public struct DocumentChange: Sendable {
    /// 按应用顺序排列的原子编辑。
    public var edits: [AppliedEdit]
    /// 变更来源。
    public var origin: ChangeOrigin
    /// 变更后的版本号(单调递增,LSP `didChange` 使用)。
    public var version: Int
    /// 变更前快照。
    public var previous: TextRope
    /// 变更后快照。
    public var snapshot: TextRope
    /// 撤销/重做时应还原的选区(普通编辑为 nil)。
    public var restoredSelections: [Selection]?

    public init(edits: [AppliedEdit], origin: ChangeOrigin, version: Int, previous: TextRope, snapshot: TextRope, restoredSelections: [Selection]?) {
        self.edits = edits
        self.origin = origin
        self.version = version
        self.previous = previous
        self.snapshot = snapshot
        self.restoredSelections = restoredSelections
    }
}

/// 文档层错误。
public enum EditorDocumentError: Error, Equatable {
    /// 编辑区间超出文本范围。
    case rangeOutOfBounds(TextSpan)
    /// 同一批编辑存在重叠区间。
    case overlappingEdits
}

/// 一条待应用的编辑(坐标相对应用前的文本)。
public struct DocumentEdit: Sendable, Equatable {
    public var range: TextSpan
    public var text: String

    public init(range: TextSpan, text: String) {
        self.range = range
        self.text = text
    }
}

/// 共享编辑文档(仅主线程变更)。
@MainActor
public final class EditorDocument {
    /// 当前文本快照(不可变,可传给后台任务)。
    public private(set) var snapshot: TextRope
    /// 版本号:每次变更(含撤销/重做)递增。
    public private(set) var version: Int = 0
    /// 保存时还原用的换行风格。
    public var lineEnding: LineEnding
    /// 装载时是否混用了多种换行风格。
    public private(set) var hadMixedLineEndings: Bool

    private var undoStack = UndoStack()
    private var savedMarker = 0
    private var observers: [Int: @MainActor (DocumentChange) -> Void] = [:]
    private var nextObserverID = 1
    private let clock: @MainActor () -> TimeInterval

    /// 从文本创建文档(自动归一换行)。
    /// - Parameters:
    ///   - text: 原始文本
    ///   - clock: 时间源(测试可注入以控制撤销合并)
    public init(text: String, clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        // 绝大多数文件只含 `\n`:无 `\r` 时走流式装载,省掉整份 UTF-16 临时数组
        if !text.utf8.contains(13) {
            self.snapshot = TextRope.streaming(text)
            self.lineEnding = .lf
            self.hadMixedLineEndings = false
        } else {
            let normalized = LineEnding.normalize(ContiguousArray(text.utf16))
            self.snapshot = TextRope(utf16: normalized.units)
            self.lineEnding = normalized.dominant
            self.hadMixedLineEndings = normalized.isMixed
        }
        self.clock = clock
    }

    // MARK: 读取

    /// 总长度(UTF-16)。
    public var length: Int { snapshot.length }
    /// 行数。
    public var lineCount: Int { snapshot.lineCount }
    /// 是否有未保存的改动。
    public var isDirty: Bool { undoStack.topID != savedMarker }
    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// 全文(以 `\n` 换行)。
    public func text() -> String { snapshot.string() }

    /// 写盘用文本:把 `\n` 还原为原始换行风格。
    public func textForSaving() -> String {
        let plain = snapshot.string()
        return lineEnding == .lf ? plain : plain.replacingOccurrences(of: "\n", with: lineEnding.sequence)
    }

    /// 标记当前内容已保存(并打断撤销合并)。
    public func markSaved() {
        savedMarker = undoStack.topID
        undoStack.breakCoalescing()
    }

    /// 打断撤销合并(光标跳转等)。
    public func breakUndoCoalescing() { undoStack.breakCoalescing() }

    // MARK: 观察

    /// 注册变更观察者,返回用于移除的令牌。
    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (DocumentChange) -> Void) -> Int {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = handler
        return id
    }

    /// 移除观察者。
    public func removeObserver(_ token: Int) { observers[token] = nil }

    // MARK: 编辑

    /// 应用一批编辑(坐标均相对应用前的文本,区间不得重叠)。
    /// - Parameters:
    ///   - edits: 编辑列表,顺序任意
    ///   - selectionsBefore: 编辑前选区(撤销时还原)
    ///   - selectionsAfter: 编辑后选区(重做时还原)
    ///   - coalesceKey: 非空时,与上一同键事务在时间窗口内合并为一次撤销(连续输入、连续删除)
    /// - Throws: 区间越界或重叠时抛出 `EditorDocumentError`,文档保持不变
    @discardableResult
    public func apply(
        _ edits: [DocumentEdit],
        selectionsBefore: [Selection] = [],
        selectionsAfter: [Selection] = [],
        coalesceKey: String? = nil,
        origin: ChangeOrigin = .user
    ) throws -> DocumentChange? {
        let sorted = try validated(edits)
        if sorted.allSatisfy({ $0.range.isEmpty && $0.text.isEmpty }) { return nil }
        let previous = snapshot
        var rope = snapshot
        var applied: [AppliedEdit] = []
        applied.reserveCapacity(sorted.count)
        // 从后向前应用,前面的偏移不受影响。
        for edit in sorted.reversed() {
            let units = ContiguousArray(edit.text.utf16)
            let normalized = units.contains(13) ? LineEnding.normalize(units).units : units
            applied.append(describe(replacing: edit.range, with: normalized, in: rope))
            rope = rope.replacing(edit.range, with: normalized)
        }
        snapshot = rope
        undoStack.record(
            before: previous, after: rope, edits: applied,
            selectionsBefore: selectionsBefore, selectionsAfter: selectionsAfter,
            coalesceKey: coalesceKey, time: clock())
        return publish(edits: applied, origin: origin, previous: previous, restored: nil)
    }

    /// 便捷:单条替换。
    @discardableResult
    public func replace(_ range: TextSpan, with text: String, selectionsBefore: [Selection] = [],
                        selectionsAfter: [Selection] = [], coalesceKey: String? = nil) throws -> DocumentChange? {
        try apply([DocumentEdit(range: range, text: text)], selectionsBefore: selectionsBefore,
                  selectionsAfter: selectionsAfter, coalesceKey: coalesceKey)
    }

    /// 以外部内容整体替换(磁盘重载、Agent 写盘):只改动首尾公共部分之外的最小区间,保留撤销栈且视为已保存。
    @discardableResult
    public func applyExternal(text newText: String, markSaved: Bool = true) -> DocumentChange? {
        let normalized = LineEnding.normalize(ContiguousArray(newText.utf16))
        lineEnding = normalized.dominant
        hadMixedLineEndings = normalized.isMixed
        let incoming = normalized.units
        let old = snapshot
        // 求公共前缀与后缀,只替换中间的差异区间。
        let oldUnits = old.slice(TextSpan(location: 0, length: old.length))
        let limit = min(oldUnits.count, incoming.count)
        var prefix = 0
        while prefix < limit, oldUnits[prefix] == incoming[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == incoming[incoming.count - 1 - suffix] { suffix += 1 }
        let oldRange = TextSpan(lower: prefix, upper: oldUnits.count - suffix)
        let inserted = ContiguousArray(incoming[prefix..<(incoming.count - suffix)])
        if oldRange.isEmpty && inserted.isEmpty {
            if markSaved { savedMarker = undoStack.topID }
            return nil
        }
        let edit = describe(replacing: oldRange, with: inserted, in: old)
        let rope = old.replacing(oldRange, with: inserted)
        snapshot = rope
        undoStack.record(before: old, after: rope, edits: [edit], selectionsBefore: [], selectionsAfter: [],
                         coalesceKey: nil, time: clock())
        if markSaved { savedMarker = undoStack.topID }
        return publish(edits: [edit], origin: .external, previous: old, restored: nil)
    }

    // MARK: 撤销与重做

    /// 撤销一个事务;返回应还原的选区(无可撤销时为 nil)。
    @discardableResult
    public func undo() -> [Selection]? {
        guard let transaction = undoStack.popUndo() else { return nil }
        let previous = snapshot
        snapshot = transaction.before
        let inverse = transaction.edits.reversed().map(\.inverted)
        publish(edits: inverse, origin: .undo, previous: previous, restored: transaction.selectionsBefore)
        return transaction.selectionsBefore
    }

    /// 重做一个事务;返回应还原的选区(无可重做时为 nil)。
    @discardableResult
    public func redo() -> [Selection]? {
        guard let transaction = undoStack.popRedo() else { return nil }
        let previous = snapshot
        snapshot = transaction.after
        publish(edits: transaction.edits, origin: .redo, previous: previous, restored: transaction.selectionsAfter)
        return transaction.selectionsAfter
    }

    // MARK: 内部

    /// 描述一次替换(含附带文本与行信息),必须在替换发生之前、用替换前的文本调用。
    private func describe(replacing range: TextSpan, with inserted: ContiguousArray<UInt16>, in rope: TextRope) -> AppliedEdit {
        let startLine = rope.line(containing: range.location)
        let endLine = range.isEmpty ? startLine : rope.line(containing: range.upperBound)
        var insertedBreaks = 0
        for unit in inserted where unit == 10 { insertedBreaks += 1 }
        let keepOld = range.length <= AppliedEdit.payloadLimit
        let keepNew = inserted.count <= AppliedEdit.payloadLimit
        return AppliedEdit(location: range.location, oldLength: range.length, newLength: inserted.count,
                           inserted: keepNew ? inserted : nil, removed: keepOld ? rope.slice(range) : nil,
                           startLine: startLine, removedLines: endLine - startLine, insertedLines: insertedBreaks)
    }

    /// 校验并按位置升序排序编辑。
    private func validated(_ edits: [DocumentEdit]) throws -> [DocumentEdit] {
        let sorted = edits.sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length < $1.range.length }
        var previousEnd = 0
        for edit in sorted {
            guard edit.range.upperBound <= snapshot.length else { throw EditorDocumentError.rangeOutOfBounds(edit.range) }
            guard edit.range.location >= previousEnd else { throw EditorDocumentError.overlappingEdits }
            previousEnd = edit.range.upperBound
        }
        return sorted
    }

    @discardableResult
    private func publish(edits: [AppliedEdit], origin: ChangeOrigin, previous: TextRope, restored: [Selection]?) -> DocumentChange {
        version += 1
        let change = DocumentChange(edits: edits, origin: origin, version: version, previous: previous,
                                    snapshot: snapshot, restoredSelections: restored)
        for handler in observers.values { handler(change) }
        return change
    }
}

/// 按路径共享文档的注册表:同一文件在多个标签/窗口里复用同一 `EditorDocument`(弱引用,无人持有即释放)。
@MainActor
public final class EditorDocumentRegistry {
    /// 全局实例。
    public static let shared = EditorDocumentRegistry()

    private final class WeakBox {
        weak var document: EditorDocument?
        init(_ document: EditorDocument) { self.document = document }
    }

    private var boxes: [String: WeakBox] = [:]

    public init() {}

    /// 取得(或用 `loader` 创建)路径对应的文档。
    public func document(forPath path: String, loader: () -> String) -> EditorDocument {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = boxes[key]?.document { return existing }
        let document = EditorDocument(text: loader())
        boxes[key] = WeakBox(document)
        if boxes.count > 256 { boxes = boxes.filter { $0.value.document != nil } }
        return document
    }

    /// 仅查询已存在的文档。
    public func existingDocument(forPath path: String) -> EditorDocument? {
        boxes[URL(fileURLWithPath: path).standardizedFileURL.path]?.document
    }
}
