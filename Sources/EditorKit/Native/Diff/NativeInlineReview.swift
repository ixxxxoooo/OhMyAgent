// @author ixxxxoooo
// 行内 Diff 审阅:在「可编辑」的原生编辑器里,把一份差异画成 View Zone(已删除行 + 块头条与块级操作)
// 与整行/字符级新增底色。Agent 文件改动审阅(保留/还原)与 ⌘K 行内编辑共用。

import AppKit
import DiffKit
import EditorCore

/// 行内 Diff 审阅(挂在某个 `OMEditorView` 上)。
@MainActor
public final class NativeInlineReview {
    /// zone / 装饰 id 起点(与 Diff 视图、行内编辑卡片错开)。
    static let idBase = 0x4000_0000
    static let idLimit = 0x4100_0000

    private weak var view: OMEditorView?
    private var zoneIDs: [Int] = []
    /// 块 id → 该块在新文本里的第一行(0 起,已含偏移)。
    public private(set) var hunkLines: [Int: Int] = [:]
    /// 当前展示的块数量。
    public var hunkCount: Int { hunkLines.count }
    /// 是否正在展示。
    public var isShowing: Bool { !zoneIDs.isEmpty || !hunkLines.isEmpty }

    init(view: OMEditorView) { self.view = view }

    /// 展示一份差异。会先清掉上一次的展示。
    /// - Parameters:
    ///   - diff: 旧 → 新的行级差异(新文本必须与编辑器当前内容(或其子区间)一致)
    ///   - lineOffset: 差异第 0 行对应编辑器的第几行(行内编辑的选区不是整个文件时使用)
    ///   - pending: 只展示这些块(nil 表示全部)
    ///   - title: 块头条标题
    ///   - actions: 块级操作(参数为块 id)
    public func show(diff: FileDiff, lineOffset: Int = 0, pending: Set<Int>? = nil,
                     title: (DiffHunk) -> String, actions: [NativeDiffAction]) {
        guard let view else { return }
        clear()
        let plan = NativeDiffPlan.make(from: diff, context: 3)
        let rope = view.model.document.snapshot
        let lineHeight = CGFloat(view.model.lineHeight)
        var slots: [Int: (header: NativeDiffZoneView.Header?, deleted: [String])] = [:]
        var items: [Decoration] = []
        var nextID = Self.idBase
        var previousHunk: Int?
        var lines: [Int: Int] = [:]
        for block in plan.blocks {
            guard let hunkID = block.hunkID, pending?.contains(hunkID) ?? true else { previousHunk = block.hunkID; continue }
            let anchor = block.newStart - 1 + lineOffset
            if hunkID != previousHunk, let hunk = diff.hunks.first(where: { $0.id == hunkID }) {
                let buttons = actions.map { action in (title: action.title, handler: { action.perform(hunkID) }) }
                slots[anchor, default: (nil, [])].header = .init(title: title(hunk), actions: buttons)
                lines[hunkID] = max(block.newStart + lineOffset, 0)
            }
            previousHunk = hunkID
            let oldRange = min(block.oldStart, diff.oldLines.count)..<min(block.oldStart + block.oldCount, diff.oldLines.count)
            if !oldRange.isEmpty { slots[anchor, default: (nil, [])].deleted += Array(diff.oldLines[oldRange]) }
            for line in block.newStart..<(block.newStart + block.newCount) {
                let target = line + lineOffset
                guard target >= 0, target < rope.lineCount else { continue }
                items.append(Decoration(id: nextID, range: TextSpan(location: rope.lineStart(target), length: rope.lineLength(target)),
                                        kind: .agentAdded, removesWhenCollapsed: false))
                nextID += 1
            }
            for pair in block.pairs {
                let target = pair.newLine + lineOffset
                guard target >= 0, target < rope.lineCount, diff.newLines.indices.contains(pair.newLine) else { continue }
                let text = diff.newLines[pair.newLine]
                let lower = NativeDiffView.utf16Offset(of: pair.newRange.lowerBound, in: text)
                let upper = NativeDiffView.utf16Offset(of: pair.newRange.upperBound, in: text)
                guard upper > lower else { continue }
                items.append(Decoration(id: nextID, range: TextSpan(location: rope.lineStart(target) + lower, length: upper - lower),
                                        kind: .custom(OMEditorView.diffCharAddedCode), removesWhenCollapsed: false))
                nextID += 1
            }
        }
        var zones: [ViewZone] = []
        var zoneFactories: [(id: Int, make: @MainActor () -> NSView)] = []
        var zoneID = Self.idBase
        for (anchor, slot) in slots.sorted(by: { $0.key < $1.key }) {
            let height = (slot.header == nil ? 0 : NativeDiffZoneView.headerHeight) + CGFloat(slot.deleted.count) * lineHeight
            guard height > 0 else { continue }
            zones.append(ViewZone(id: zoneID, afterLine: anchor, height: Double(height)))
            let header = slot.header, deleted = slot.deleted, textInset = view.textInset
            zoneFactories.append((zoneID, {
                NativeDiffZoneView(header: header, deleted: deleted, padHeight: 0, font: EditorFontPrefs.preferredFont,
                                   lineHeight: lineHeight, textInset: textInset)
            }))
            zoneIDs.append(zoneID)
            zoneID += 1
        }
        view.model.setZones(view.model.zones.filter { !(Self.idBase..<Self.idLimit).contains($0.id) } + zones)
        view.setLazyZoneViews(zoneFactories)
        view.model.decorations.removeAll { $0.id >= Self.idBase && $0.id < Self.idLimit }
        for item in items { view.model.decorations.insert(item) }
        hunkLines = lines
        view.layoutZoneViews()
        view.needsDisplay = true
    }

    /// 清除展示(zone 与装饰)。
    public func clear() {
        guard let view, isShowing else { return }
        view.setLazyZoneViews([], removing: zoneIDs)
        zoneIDs = []
        hunkLines = [:]
        view.model.setZones(view.model.zones.filter { !(Self.idBase..<Self.idLimit).contains($0.id) })
        view.model.decorations.removeAll { $0.id >= Self.idBase && $0.id < Self.idLimit }
        view.needsDisplay = true
    }
}
