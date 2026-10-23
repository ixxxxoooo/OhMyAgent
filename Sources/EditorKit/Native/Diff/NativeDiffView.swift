// @author ixxxxoooo
// 原生 Diff 编辑器:基于 `OMEditorView` 的并排 / 内联两种布局。
// - 并排:左右各一个只读编辑器,通过「对齐占位 zone」让改动块左右对齐,滚动与折叠互相镜像;
// - 内联:单个编辑器显示新文本,已删除的行以 zone 形式插在改动块之前;
// - 两种布局都带字符级高亮、未改动区折叠、块头条(块标题 + 暂存/放弃等块级操作)与块间跳转。

import AppKit
import DesignSystem
import DiffKit
import EditorCore
import OMLog
import SwiftUI

/// Diff 布局。
public enum NativeDiffLayout: Sendable {
    case sideBySide, inline
}

/// 原生 Diff 容器视图。
@MainActor
public final class NativeDiffView: NSView {
    /// 行级装饰 id 起点(整行底色)。
    private static let lineBase = 0x3000_0000
    /// 字符级装饰 id 起点。
    private static let charBase = 0x3800_0000

    public private(set) var layoutMode: NativeDiffLayout = .sideBySide
    /// 当前方案(测试与跳转用)。
    public private(set) var plan = NativeDiffPlan.empty
    /// 左侧(旧)编辑器;内联模式为 nil。
    public private(set) var oldEditor: OMEditorView?
    /// 右侧(新)编辑器;内联模式下唯一的编辑器。
    public private(set) var newEditor: OMEditorView?
    private let divider = NSView()
    private var syncing = false
    private var foldSyncing = false
    private var language: SyntaxLanguage = .plain

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        divider.wantsLayer = true
        addSubview(divider)
        divider.isHidden = true
        setAccessibilityElement(false)
    }

    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// 改动块数量。
    public var blockCount: Int { plan.blocks.count }

    /// 展示一份差异(重建两侧编辑器内容、装饰、zone 与折叠)。
    /// - Parameters:
    ///   - old: 旧文本
    ///   - new: 新文本
    ///   - diff: 行级差异
    ///   - mode: 布局
    ///   - language: 语法
    ///   - fileName: 文件名(用于缩进等推断)
    ///   - actions: 块级操作(出现在每个块头条右侧)
    public func show(old: String, new: String, diff: FileDiff, mode: NativeDiffLayout, language: SyntaxLanguage,
                     fileName: String?, actions: [NativeDiffAction]) {
        layoutMode = mode
        self.language = language
        plan = NativeDiffPlan.make(from: diff)
        let newView = ensure(&newEditor, text: new, language: language, fileName: fileName)
        if mode == .sideBySide {
            let oldView = ensure(&oldEditor, text: old, language: language, fileName: fileName)
            install(oldView, text: old)
            install(newView, text: new)
            decorate(oldView, diff: diff, isOld: true)
            decorate(newView, diff: diff, isOld: false)
            zones(oldView, diff: diff, isOld: true, actions: actions)
            zones(newView, diff: diff, isOld: false, actions: actions)
            applyFolds(oldView, regions: plan.folds.map(\.old))
            applyFolds(newView, regions: plan.folds.map(\.new))
            wireSync(oldView, newView)
        } else {
            oldEditor?.removeFromSuperview()
            oldEditor = nil
            install(newView, text: new)
            decorate(newView, diff: diff, isOld: false)
            zones(newView, diff: diff, isOld: false, actions: actions, inline: true)
            applyFolds(newView, regions: plan.folds.map(\.new))
            newView.onScroll = nil
        }
        divider.isHidden = mode != .sideBySide
        needsLayout = true
    }

    /// 滚动到第 `index` 个改动块(越界时夹取)。
    public func scrollToBlock(_ index: Int) {
        guard !plan.blocks.isEmpty, let editor = newEditor else { return }
        let block = plan.blocks[min(max(index, 0), plan.blocks.count - 1)]
        let line = max(block.newStart - 1, 0)
        editor.scrollToLine(line, centered: false)
        oldEditor?.scrollToLine(max(block.oldStart - 1, 0), centered: false)
    }

    /// 滚动到某个 Git 块的第一个改动块。
    public func scrollToHunk(_ hunkID: Int) {
        if let index = plan.blocks.firstIndex(where: { $0.hunkID == hunkID }) { scrollToBlock(index) }
    }

    // MARK: 装配

    private func ensure(_ slot: inout OMEditorView?, text: String, language: SyntaxLanguage, fileName: String?) -> OMEditorView {
        if let slot { return slot }
        let model = NativeEditorModel(document: EditorDocument(text: text), language: language)
        model.isEditable = false
        model.fileName = fileName
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.chrome = []
        addSubview(view)
        slot = view
        return view
    }

    /// 文本不同才替换,保持语法与滚动位置稳定。
    private func install(_ view: OMEditorView, text: String) {
        let doc = view.model.document
        if doc.text() != text {
            do {
                try doc.apply([DocumentEdit(range: TextSpan(location: 0, length: doc.length), text: text)],
                              selectionsBefore: view.model.selections.selections, selectionsAfter: [Selection(caret: 0)], coalesceKey: nil)
            } catch {
                Log.editor.error("Diff 视图写入文档失败: \(error.localizedDescription)")
            }
        }
        if view.model.language != language {
            view.model.language = language
            view.reloadSyntax()
        }
    }

    private func applyFolds(_ view: OMEditorView, regions: [EditorCore.FoldRegion]) {
        view.model.setFoldRegions(regions)
        for region in regions { view.model.fold(line: region.startLine) }
    }

    // MARK: 装饰

    /// 整行与字符级装饰。
    private func decorate(_ view: OMEditorView, diff: FileDiff, isOld: Bool) {
        let rope = view.model.document.snapshot
        var items: [Decoration] = []
        var nextID = Self.lineBase
        for block in plan.blocks {
            let start = isOld ? block.oldStart : block.newStart
            let count = isOld ? block.oldCount : block.newCount
            guard count > 0 else { continue }
            let kind: DecorationKind = isOld ? .gitRemoved : .gitAdded
            for line in start..<(start + count) where line < rope.lineCount {
                let begin = rope.lineStart(line)
                items.append(Decoration(id: nextID, range: TextSpan(location: begin, length: rope.lineLength(line)), kind: kind, removesWhenCollapsed: false))
                nextID += 1
            }
        }
        var charID = Self.charBase
        let lines = isOld ? diff.oldLines : diff.newLines
        for block in plan.blocks {
            for pair in block.pairs {
                let line = isOld ? pair.oldLine : pair.newLine
                guard lines.indices.contains(line), line < rope.lineCount else { continue }
                let range = isOld ? pair.oldRange : pair.newRange
                let text = lines[line]
                let lower = Self.utf16Offset(of: range.lowerBound, in: text), upper = Self.utf16Offset(of: range.upperBound, in: text)
                guard upper > lower else { continue }
                items.append(Decoration(id: charID, range: TextSpan(location: rope.lineStart(line) + lower, length: upper - lower),
                                        kind: .custom(isOld ? OMEditorView.diffCharRemovedCode : OMEditorView.diffCharAddedCode),
                                        removesWhenCollapsed: false))
                charID += 1
            }
        }
        view.model.decorations.replace(kinds: [.gitAdded, .gitRemoved, .custom(OMEditorView.diffCharAddedCode), .custom(OMEditorView.diffCharRemovedCode)],
                                       with: items)
        view.needsDisplay = true
    }

    /// 把 `Character` 偏移换算成 UTF-16 偏移。
    static func utf16Offset(of characters: Int, in text: String) -> Int {
        guard characters > 0 else { return 0 }
        let index = text.index(text.startIndex, offsetBy: characters, limitedBy: text.endIndex) ?? text.endIndex
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    // MARK: View Zone

    /// 块头条、对齐占位与(内联模式的)已删除行。
    private func zones(_ view: OMEditorView, diff: FileDiff, isOld: Bool, actions: [NativeDiffAction], inline: Bool = false) {
        struct Slot { var header: NativeDiffZoneView.Header?; var deleted: [String] = []; var pad = 0 }
        var slots: [Int: Slot] = [:]
        var previousHunk: Int?
        let lineHeight = CGFloat(view.model.lineHeight)
        for block in plan.blocks {
            let start = isOld ? block.oldStart : block.newStart
            let count = isOld ? block.oldCount : block.newCount
            // 块头条:每个 Git 块的第一个改动块出现一次。
            if let hunkID = block.hunkID, hunkID != previousHunk {
                let title = diff.hunks.first { $0.id == hunkID }?.header ?? ""
                let buttons = actions.map { action in (title: action.title, handler: { action.perform(hunkID) }) }
                slots[start - 1, default: Slot()].header = .init(title: title, actions: isOld && !inline ? [] : buttons)
            }
            previousHunk = block.hunkID
            if inline {
                // 已删除行插在新文本改动块之前(与头条同一个 zone)。
                let removed = diff.oldLines[min(block.oldStart, diff.oldLines.count)..<min(block.oldStart + block.oldCount, diff.oldLines.count)]
                if !removed.isEmpty { slots[start - 1, default: Slot()].deleted = Array(removed) }
            } else {
                let pad = NativeDiffPlan.padding(for: block, oldSide: isOld)
                if pad > 0 { slots[start + count - 1, default: Slot()].pad += pad }
            }
        }
        var zones: [ViewZone] = []
        var id = 1
        for (anchor, slot) in slots.sorted(by: { $0.key < $1.key }) {
            let height = (slot.header == nil ? 0 : NativeDiffZoneView.headerHeight)
                + CGFloat(slot.deleted.count + slot.pad) * lineHeight
            guard height > 0 else { continue }
            zones.append(ViewZone(id: id, afterLine: anchor, height: Double(height)))
            let content = NativeDiffZoneView(header: slot.header, deleted: slot.deleted,
                                             padHeight: CGFloat(slot.pad) * lineHeight, font: EditorFontPrefs.preferredFont,
                                             lineHeight: lineHeight, textInset: view.textInset)
            view.setZoneView(content, forZone: id)
            id += 1
        }
        // 清理多余的旧 zone 视图。
        for stale in view.zoneViews.keys where stale >= id { view.setZoneView(nil, forZone: stale) }
        view.model.setZones(zones)
        view.layoutZoneViews()
    }

    // MARK: 同步

    /// 左右滚动与折叠互相镜像。
    private func wireSync(_ old: OMEditorView, _ new: OMEditorView) {
        old.onScroll = { [weak self, weak old, weak new] in
            guard let self, !self.syncing, let old, let new else { return }
            self.syncing = true
            new.scroll(toX: old.scrollX, y: old.scrollY)
            self.syncing = false
        }
        new.onScroll = { [weak self, weak old, weak new] in
            guard let self, !self.syncing, let old, let new else { return }
            self.syncing = true
            old.scroll(toX: new.scrollX, y: new.scrollY)
            self.syncing = false
        }
        mirrorFolds(from: old, to: new, regions: { $0.old.startLine }, target: { $0.new.startLine })
        mirrorFolds(from: new, to: old, regions: { $0.new.startLine }, target: { $0.old.startLine })
    }

    /// 一侧折叠/展开时同步到另一侧。
    private func mirrorFolds(from source: OMEditorView, to destination: OMEditorView,
                             regions: @escaping (NativeDiffFold) -> Int, target: @escaping (NativeDiffFold) -> Int) {
        let prior = source.model.onLayoutChange
        source.model.onLayoutChange = { [weak self, weak source, weak destination] in
            prior?()
            guard let self, !self.foldSyncing, let source, let destination else { return }
            self.foldSyncing = true
            defer { self.foldSyncing = false }
            for fold in self.plan.folds {
                let collapsed = source.model.folds.isCollapsed(startLine: regions(fold))
                let start = target(fold)
                if collapsed != destination.model.folds.isCollapsed(startLine: start) {
                    collapsed ? destination.model.fold(line: start) : destination.model.unfold(line: start)
                }
            }
        }
    }

    // MARK: 布局

    public override func layout() {
        super.layout()
        if layoutMode == .sideBySide, let oldEditor, let newEditor {
            let half = floor((bounds.width - 1) / 2)
            oldEditor.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
            divider.frame = CGRect(x: half, y: 0, width: 1, height: bounds.height)
            divider.layer?.backgroundColor = NSColor(OMColors.hairline).cgColor
            newEditor.frame = CGRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
        } else {
            newEditor?.frame = bounds
        }
    }
}

/// SwiftUI 包装。
public struct NativeDiffEditor: NSViewRepresentable {
    public var old: String
    public var new: String
    public var diff: FileDiff
    public var layoutMode: NativeDiffLayout
    public var language: SyntaxLanguage
    public var fileName: String?
    public var actions: [NativeDiffAction]
    /// 外部请求跳到的 Git 块 id(变化时触发)。
    public var targetHunk: Int?
    public var onBlockCount: ((Int) -> Void)?

    public init(old: String, new: String, diff: FileDiff, layoutMode: NativeDiffLayout, language: SyntaxLanguage, fileName: String?,
                actions: [NativeDiffAction] = [], targetHunk: Int? = nil, onBlockCount: ((Int) -> Void)? = nil) {
        self.old = old
        self.new = new
        self.diff = diff
        self.layoutMode = layoutMode
        self.language = language
        self.fileName = fileName
        self.actions = actions
        self.targetHunk = targetHunk
        self.onBlockCount = onBlockCount
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NativeDiffView { NativeDiffView() }

    public func updateNSView(_ view: NativeDiffView, context: Context) {
        let key = "\(old.hashValue)|\(new.hashValue)|\(layoutMode)|\(language)|\(actions.map(\.title))"
        if context.coordinator.key != key {
            context.coordinator.key = key
            view.show(old: old, new: new, diff: diff, mode: layoutMode, language: language, fileName: fileName, actions: actions)
            onBlockCount?(view.blockCount)
        }
        // 首次展示不滚动(停在文件顶部);之后目标块变化才跳转。
        if let targetHunk, context.coordinator.hunk != targetHunk {
            let isFirst = context.coordinator.hunk == nil
            context.coordinator.hunk = targetHunk
            if !isFirst { view.scrollToHunk(targetHunk) }
        }
    }

    @MainActor
    public final class Coordinator {
        var key = ""
        var hunk: Int?
    }
}
