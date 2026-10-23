// @author ixxxxoooo
// 原生代码编辑视图(「native2」引擎):自绘 NSView,不使用 NSScrollView/NSTextView。
// 文本由 `EditorCore` 的 rope 文档承载,排版用 CoreText 行缓存,滚动与光标都由本视图自己管理,
// 因此输入、滚动、打开超大文件的开销只与「可见行数」有关,而与文档大小无关。

import AppKit
import CoreText
import DesignSystem
import EditorCore
import OMLog
import SwiftUI

/// 原生编辑视图。
@MainActor
public final class OMEditorView: NSView {
    // MARK: 状态

    /// 编辑器模型(文档、选区、折叠、装饰)。
    public let model: NativeEditorModel
    /// 语法片段仓库。
    let tokens = NativeTokenStore()
    /// 行排版缓存。
    var cache: NativeLayoutCache
    /// 当前主题。
    public private(set) var theme: EditorTheme
    /// 编辑器字体。
    public private(set) var font: NSFont
    /// 水平/垂直滚动偏移(点)。
    public internal(set) var scrollX: CGFloat = 0
    public internal(set) var scrollY: CGFloat = 0
    /// 行号栏宽度(随行数位数变化)。
    public internal(set) var gutterWidth: CGFloat = 56
    /// 顶部留白与文本左内边距。
    let topInset: CGFloat = 4
    let textInset: CGFloat = 10
    /// 折叠箭头列宽度。
    let foldColumnWidth: CGFloat = 14
    /// 是否按视图宽度软换行。
    public var wrapsLines = false { didSet { if wrapsLines != oldValue { applyWrapSettings(immediate: true) } } }
    /// 输入法组合文本范围(已写入文档)。
    var composition: NSRange?
    /// 光标闪烁状态。
    var caretVisible = true
    var caretTimer: Timer?
    /// 行标记(新增/删除/修改/Agent)与诊断行。
    public var lineMarkers: [Int: LineMarker] = [:] { didSet { markersRevision &+= 1; needsDisplay = true } }
    var markersRevision = 0
    public var diagnosticLines: [Int: EditorDiagnostic.Severity] = [:] { didSet { needsDisplay = true } }
    /// 注册到视图里的 View Zone 内容视图(按 zone id)。
    var zoneViews: [Int: NSView] = [:]
    /// 文档观察者令牌。
    var observerToken: Int?
    /// 滚动条交互状态。
    var scrollbarVisibleUntil: TimeInterval = 0
    var scrollbarHideTask: Task<Void, Never>?
    var scrollbarDrag: ScrollbarDrag?
    /// 鼠标拖选状态。
    var dragMode: DragMode = .none
    var dragAnchor = TextSpan(location: 0, length: 0)
    var columnAnchor: (line: Int, column: Double)?
    var autoscrollTimer: Timer?
    var lastMouseLocation = CGPoint.zero
    /// IDE 外围视图选项(缩略图、粘性滚动、折叠、概览尺)。
    public var chrome: EditorChrome = [] { didSet { if chrome != oldValue { chromeDidChange() } } }
    /// 缩略图视图(启用时存在)。
    var minimap: NativeMinimapView?
    /// 括号索引(彩色括号与括号匹配)。
    let brackets = NativeBracketStore()
    /// 粘性滚动当前显示的块头行与计算键(顶行、文档版本)。
    var stickyLines: [Int] = []
    var stickyKey = StickyKey(topLine: -1, version: -1)
    /// 粘性区域高度(点)。
    var stickyHeight: CGFloat { CGFloat(stickyLines.count) * lineHeight }
    /// 概览尺标记缓存。
    var overviewMarks: [OverviewMark] = []
    var overviewKey = OverviewKey()
    /// 括号匹配装饰是否存在(避免每次选区变化都去清理)。
    var hasBracketMatch = false
    /// 空白字符渲染模式与 Unicode 高亮开关。
    public var whitespaceRendering = OMEditorView.preferredWhitespaceRendering { didSet { needsDisplay = true } }
    public var highlightsUnicode = true { didSet { needsDisplay = true } }
    /// 鼠标是否悬停在行号栏(折叠箭头据此显示)。
    var gutterHovered = false
    /// 查找条模型与宿主(⌘F 打开)。
    let findModel = EditorFindModel()
    var findHost: NSHostingView<EditorFindBar>?
    /// 当前查找结果(升序)。
    var findMatches: [TextSpan] = []
    /// 查找后台任务与代数(过期结果丢弃)。
    var findTask: Task<Void, Never>?
    var findGeneration = 0
    /// 最近获得焦点的原生编辑器(菜单命令在焦点不在文本区时的兜底)。
    static weak var lastFocused: OMEditorView?
    /// 语言智能控制器(补全、悬停、签名、灯泡、内嵌提示、语义着色)。
    public private(set) lazy var languageController = NativeLanguageController(view: self)
    /// Agent 改动 / 行内编辑的行内 Diff 审阅(zone + 行底色)。
    public private(set) lazy var inlineReview = NativeInlineReview(view: self)
    /// ⌘K 行内编辑控制器。
    public private(set) lazy var inlineEdit = NativeInlineEdit(view: self)
    /// Tab 幽灵补全。
    public private(set) lazy var inlineSuggestion = NativeInlineSuggestion(view: self)
    /// ⌘L / ⌘⇧L:把选区引用到对话(参数为 UTF-16 选区;空选区表示只切到对话输入框)。
    public var onReferenceSelection: ((NSRange) -> Void)?
    /// 窗口大小变化时的防抖任务。
    var wrapTask: Task<Void, Never>?
    /// 主题监听。
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    // MARK: 回调

    /// 文档发生变化(用户编辑或外部写入)。
    public var onTextChange: ((DocumentChange) -> Void)?
    /// 选区变化。
    public var onSelectionChange: (() -> Void)?
    /// ⌘ 点击某个偏移(跳转定义)。
    public var onCommandClick: ((Int) -> Void)?
    /// 点击行号栏的标记区(参数为行号)。
    public var onGutterClick: ((Int) -> Void)?
    /// 滚动位置变化。
    public var onScroll: (() -> Void)?

    enum DragMode { case none, character, word, line, column }
    struct StickyKey: Equatable { var topLine: Int; var version: Int }
    struct ScrollbarDrag { var vertical: Bool; var grabOffset: CGFloat }

    // MARK: 初始化

    /// 创建视图。
    /// - Parameters:
    ///   - model: 编辑器模型
    ///   - theme: 主题
    ///   - font: 等宽字体
    public init(model: NativeEditorModel, theme: EditorTheme, font: NSFont) {
        self.model = model
        self.theme = theme
        self.font = font
        cache = NativeLayoutCache(model: model, tokens: tokens, font: font, theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        model.setLineHeight(Double(EditorFontPrefs.lineHeight(for: font)))
        model.setMetrics(ColumnMetrics(tabSize: model.indentUnit == "\t" ? 4 : max(model.indentUnit.count, 2)))
        model.onDocumentChange = { [weak self] change in self?.modelDidChange(change) }
        model.onSelectionChange = { [weak self] in self?.selectionDidChange() }
        model.onLayoutChange = { [weak self] in self?.modelLayoutDidChange() }
        cache.brackets = brackets
        brackets.onUpdate = { [weak self] in
            guard let self else { return }
            self.cache.clear()
            self.needsDisplay = true
        }
        tokens.onUpdate = { [weak self] in
            guard let self else { return }
            self.cache.clear()
            self.minimap?.invalidateAll()
            self.needsDisplay = true
        }
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTheme() }
        }
        updateGutterWidth()
        reloadSyntax()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override var wantsUpdateLayer: Bool { false }

    // MARK: 几何

    /// 行高(点)。
    var lineHeight: CGFloat { CGFloat(model.lineHeight) }
    /// 一个字符列的宽度。
    var columnWidth: CGFloat { cache.columnWidth }
    /// 文本区域(行号栏右侧)。
    var textArea: CGRect { CGRect(x: gutterWidth, y: 0, width: max(bounds.width - gutterWidth - rightInset, 0), height: bounds.height) }
    /// 文本原点 x(含水平滚动)。
    var textOriginX: CGFloat { gutterWidth + textInset - scrollX }

    /// 视图行顶部的 y(视图坐标)。
    func rowTop(_ row: Int) -> CGFloat { CGFloat(model.zoneLayout.y(ofRow: row)) + topInset - scrollY }

    /// 最大垂直滚动偏移:允许把最后一行滚到接近顶部。
    var maxScrollY: CGFloat { max(0, CGFloat(model.contentHeight) + topInset - lineHeight * 3) }

    /// 最大水平滚动偏移(软换行时为 0)。
    var maxScrollX: CGFloat {
        guard !wrapsLines else { return 0 }
        let content = CGFloat(model.contentColumns) * columnWidth + textInset * 2 + 24
        return max(0, content - textArea.width)
    }

    /// 视图坐标 → 视图行(夹取)。
    func row(atY y: CGFloat) -> Int {
        let total = model.lineMap.totalRows
        guard total > 0 else { return 0 }
        switch model.zoneLayout.hit(y: Double(y - topInset + scrollY), totalRows: total) {
        case .row(let row, _): return min(max(row, 0), total - 1)
        case .zone(let index, _): return min(max(model.zoneLayout.anchorRow(ofZoneAt: index), 0), total - 1)
        }
    }

    /// 视图坐标 → 文档偏移。
    func offset(at point: CGPoint) -> Int {
        let total = model.lineMap.totalRows
        guard total > 0 else { return 0 }
        let contentY = point.y - topInset + scrollY
        let row: Int
        if contentY < 0 { row = 0 } else { row = self.row(atY: point.y) }
        guard let found = cache.rowLayout(forRow: row) else { return 0 }
        let lineStart = model.document.snapshot.lineStart(found.line)
        return lineStart + found.layout.offset(forX: point.x - textOriginX)
    }

    /// 偏移处光标的矩形(视图坐标)。
    func caretRect(forOffset offset: Int, width: CGFloat = 2) -> CGRect {
        let row = model.viewRow(ofOffset: offset)
        guard let found = cache.rowLayout(forRow: row) else { return CGRect(x: textOriginX, y: rowTop(0), width: width, height: lineHeight) }
        let lineStart = model.document.snapshot.lineStart(found.line)
        let x = textOriginX + found.layout.x(forOffset: offset - lineStart)
        return CGRect(x: x, y: rowTop(row), width: width, height: lineHeight)
    }

    /// 可见的偏移区间(给语法仓库与装饰查询)。
    func visibleOffsetRange() -> NSRange {
        let rope = model.document.snapshot
        guard model.lineMap.totalRows > 0 else { return NSRange(location: 0, length: 0) }
        let first = row(atY: 0)
        let last = row(atY: bounds.height)
        let firstLine = model.lineMap.locate(row: first).line
        let lastLine = model.lineMap.locate(row: last).line
        let start = rope.lineStart(firstLine)
        let end = lastLine + 1 < rope.lineCount ? rope.lineStart(lastLine + 1) : rope.length
        return NSRange(location: start, length: max(end - start, 0))
    }

    // MARK: 模型回调

    private func modelDidChange(_ change: DocumentChange) {
        if change.edits.isEmpty {
            cache.clear()
        } else {
            cache.documentChanged(change)
            tokens.documentChanged(change, desired: visibleOffsetRange())
            brackets.documentChanged(change)
            minimap?.documentDidChange()
        }
        refreshSticky()
        updateGutterWidth()
        clampScroll()
        layoutZoneViews()
        restartCaretBlink()
        needsDisplay = true
        if findHost != nil, !change.edits.isEmpty { scheduleFindRefresh() }
        onTextChange?(change)
        if !change.edits.isEmpty { languageController.documentChanged(); inlineEdit.documentDidChange(); inlineSuggestion.documentDidChange() }
        if !change.edits.isEmpty { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    /// 折叠导致视图行映射变化:重排并重绘。
    private func modelLayoutDidChange() {
        clampScroll()
        layoutZoneViews()
        refreshSticky()
        minimap?.invalidateAll()
        overviewKey = OverviewKey()
        needsDisplay = true
    }

    private func selectionDidChange() {
        restartCaretBlink()
        revealPrimaryCaret()
        updateBracketMatch()
        minimap?.needsDisplay = true
        needsDisplay = true
        onSelectionChange?()
        languageController.selectionChanged()
        inlineSuggestion.selectionDidChange()
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    /// 重新装入语法(切换文件/语言后调用)。
    public func reloadSyntax() {
        cache.clear()
        tokens.load(snapshot: model.document.snapshot, language: model.language, desired: visibleOffsetRange())
        brackets.load(snapshot: model.document.snapshot, language: model.language)
        stickyKey = StickyKey(topLine: -1, version: -1)
        needsDisplay = true
    }

    // MARK: 主题与字体

    /// 更换主题与字体。
    public func apply(theme: EditorTheme, font: NSFont) {
        self.theme = theme
        let fontChanged = font != self.font
        self.font = font
        cache.update(font: font, theme: theme, appearance: effectiveAppearance)
        if fontChanged {
            model.setLineHeight(Double(EditorFontPrefs.lineHeight(for: font)))
            applyWrapSettings(immediate: true)
        }
        updateGutterWidth()
        clampScroll()
        layoutZoneViews()
        needsDisplay = true
    }

    private func refreshTheme() {
        apply(theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cache.update(font: font, theme: theme, appearance: effectiveAppearance)
        needsDisplay = true
    }

    // MARK: 行号栏

    /// 按最大行号位数计算行号栏宽度。
    func updateGutterWidth() {
        let digits = max(String(model.document.lineCount).count, 3)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]).width
        let next = ceil(CGFloat(digits) * digitWidth) + 8 + 8 + foldColumnWidth
        if abs(next - gutterWidth) > 0.5 {
            gutterWidth = next
            applyWrapSettings(immediate: false)
        }
    }

    // MARK: 软换行

    /// 按当前宽度更新模型的换行列数。
    func applyWrapSettings(immediate: Bool) {
        wrapTask?.cancel()
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let columns: Double? = self.wrapsLines
                ? Double(max(((self.textArea.width - self.textInset * 2 - 12) / self.columnWidth).rounded(.down), 8)) : nil
            if self.model.wrapColumns != columns || self.model.lineHeight != Double(EditorFontPrefs.lineHeight(for: self.font)) {
                self.model.setLineHeight(Double(EditorFontPrefs.lineHeight(for: self.font)))
                self.model.setWrapColumns(columns)
            }
            self.cache.clear()
            self.clampScroll()
            self.layoutZoneViews()
            self.needsDisplay = true
        }
        if immediate || !inLiveResize {
            apply()
        } else {
            wrapTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                if !Task.isCancelled { apply() }
            }
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, wrapsLines { applyWrapSettings(immediate: false) }
        clampScroll()
        layoutMinimap()
        layoutZoneViews()
        languageController.repositionOverlays()
        tokens.ensureCovered(visibleOffsetRange())
        needsDisplay = true
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if wrapsLines { applyWrapSettings(immediate: true) }
    }

    // MARK: 滚动

    /// 夹取滚动偏移。
    func clampScroll() {
        scrollY = min(max(scrollY, 0), maxScrollY)
        scrollX = min(max(scrollX, 0), maxScrollX)
    }

    /// 滚动到指定偏移。
    public func scroll(toX x: CGFloat? = nil, y: CGFloat? = nil) {
        let oldX = scrollX, oldY = scrollY
        if let x { scrollX = x }
        if let y { scrollY = y }
        clampScroll()
        guard oldX != scrollX || oldY != scrollY else { return }
        didScroll()
    }

    /// 相对滚动。
    func scrollBy(dx: CGFloat, dy: CGFloat) {
        scroll(toX: scrollX + dx, y: scrollY + dy)
    }

    func didScroll() {
        refreshSticky()
        minimap?.editorDidScroll()
        layoutZoneViews()
        tokens.ensureCovered(visibleOffsetRange())
        showScrollbars()
        needsDisplay = true
        onScroll?()
        languageController.scrolled()
    }

    /// 保证偏移可见(上下留 `margin` 行,左右留若干列)。
    public func reveal(offset: Int, margin: Int = 2) {
        let rect = caretRect(forOffset: offset)
        let top = rect.minY - stickyHeight - CGFloat(margin) * lineHeight
        let bottom = rect.maxY + CGFloat(margin) * lineHeight
        var nextY = scrollY
        if top < 0 { nextY += top } else if bottom > bounds.height { nextY += bottom - bounds.height }
        var nextX = scrollX
        if !wrapsLines {
            let left = rect.minX - textArea.minX - textInset - columnWidth * 3
            let right = rect.maxX - textArea.maxX + columnWidth * 6
            if left < 0 { nextX += left } else if right > 0 { nextX += right }
        }
        scroll(toX: nextX, y: nextY)
    }

    /// 保证主光标可见。
    func revealPrimaryCaret() {
        reveal(offset: model.selections.primary.head)
    }

    /// 把某一行滚到视口顶部附近。
    public func scrollToLine(_ line: Int, centered: Bool = true) {
        let row = model.lineMap.firstRow(ofLine: min(max(line, 0), max(model.document.lineCount - 1, 0)))
        let y = CGFloat(model.zoneLayout.y(ofRow: row))
        scroll(y: centered ? y - bounds.height / 2 + lineHeight : y)
    }

    // MARK: View Zone

    /// 设置某个 View Zone 的内容视图(高度由模型里的 zone 决定)。
    public func setZoneView(_ view: NSView?, forZone id: Int) {
        zoneViews[id]?.removeFromSuperview()
        zoneViews[id] = view
        if let view { addSubview(view) }
        layoutZoneViews()
    }

    /// 按滚动位置重排所有 Zone 内容视图。
    func layoutZoneViews() {
        guard !zoneViews.isEmpty else { return }
        let layout = model.zoneLayout
        for (index, zone) in layout.zones.enumerated() {
            guard let view = zoneViews[zone.id] else { continue }
            let y = CGFloat(layout.y(ofZoneAt: index)) + topInset - scrollY
            let frame = CGRect(x: gutterWidth, y: y, width: textArea.width, height: CGFloat(zone.height))
            view.isHidden = frame.maxY < 0 || frame.minY > bounds.height
            if view.frame != frame { view.frame = frame }
        }
        let active = Set(layout.zones.map(\.id))
        for (id, view) in zoneViews where !active.contains(id) { view.isHidden = true }
    }

    // MARK: 光标闪烁

    func restartCaretBlink() {
        caretVisible = true
        caretTimer?.invalidate()
        caretTimer = nil
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return }
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretVisible.toggle()
                self.invalidateCarets()
            }
        }
    }

    /// 只重绘光标所在的矩形。
    func invalidateCarets() {
        for selection in model.selections.selections {
            let rect = caretRect(forOffset: selection.head).insetBy(dx: -2, dy: 0)
            if rect.intersects(bounds) { setNeedsDisplay(rect) }
        }
    }

    public override func becomeFirstResponder() -> Bool {
        Self.lastFocused = self
        restartCaretBlink()
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        caretTimer?.invalidate()
        caretTimer = nil
        caretVisible = true
        needsDisplay = true
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { caretTimer?.invalidate(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        restartCaretBlink()
    }

    @objc private func windowKeyChanged() {
        restartCaretBlink()
        needsDisplay = true
    }
}
