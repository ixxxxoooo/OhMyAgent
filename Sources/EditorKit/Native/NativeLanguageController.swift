// @author ixxxxoooo
// 原生编辑器的语言智能控制器:补全窗、悬停卡片、签名帮助、灯泡与代码操作、定义/引用跳转、
// 内嵌提示与语义着色刷新、格式化。视图把键盘/鼠标/文档事件转给它,它负责请求与自绘浮层。

import AppKit
import DesignSystem
import EditorCore
import OMLog
import SwiftUI

/// 语义标记装饰的 `custom` 编码起点(`0x1000 + SyntaxKind.rawValue`)。
let nativeSemanticBase = 0x1000
/// 内嵌提示与语义标记装饰的 id 起点。
private let inlayDecorationBase = 0x7000_0000
private let semanticDecorationBase = 0x7800_0000

/// 浮层列表的用途。
private enum PopupMode {
    case completion
    case actions([NativeCodeActionItem])
    case locations([NativeLocation])
}

@MainActor
public final class NativeLanguageController {
    weak var view: OMEditorView?
    /// 语言智能回调集合;设置后会刷新内嵌提示与语义着色。
    public var services = NativeLanguageServices() {
        didSet { servicesDidChange() }
    }

    private var lastPreparedVersion = -1

    // 浮层列表(同一时间只有一个)
    private var popup: NativePopupListView?
    private var popupMode: PopupMode?
    private var popupAnchor = 0
    private var completionItems: [NativeCompletionItem] = []
    private var completionFiltered: [(item: NativeCompletionItem, indices: [Int])] = []
    private var completionTask: Task<Void, Never>?
    private var completionGeneration = 0
    private var autoTriggerTask: Task<Void, Never>?

    // 悬停
    private var hoverCard: NativeInfoCardView?
    private var hoverWord: TextSpan?
    private var hoverTask: Task<Void, Never>?

    // 签名
    private var signatureCard: NativeInfoCardView?
    private var signatureTask: Task<Void, Never>?

    // 灯泡
    private var lightbulb: NativeLightbulbView?
    private var codeActionTask: Task<Void, Never>?
    private var availableActions: [NativeCodeActionItem] = []

    // 内嵌提示与语义着色
    private var inlayTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?

    init(view: OMEditorView) { self.view = view }

    // MARK: 对外接口

    /// 当前完整文本(同步取,适合按需调用)。
    public func currentText() -> String { view?.model.document.snapshot.string() ?? "" }

    /// 应用一批编辑(一次撤销);返回是否修改了文档。
    @discardableResult
    public func applyEdits(_ edits: [NativeTextEdit]) -> Bool { view?.model.applyTextEdits(edits) ?? false }

    // MARK: 同步

    /// 请求前把最新文本同步给服务器(同一文档版本只同步一次)。
    private func prepare() {
        guard let view else { return }
        let version = view.model.document.version
        guard version != lastPreparedVersion else { return }
        lastPreparedVersion = version
        let document = view.model.document
        services.prepare?({ document.snapshot.string() })
    }

    private func servicesDidChange() {
        services.attach?(self)
        if services.isEmpty {
            dismissPopup(); hideHover(); hideSignature(); hideLightbulb()
            clearDecorations()
        } else {
            lastPreparedVersion = -1
            scheduleRefresh(delay: .milliseconds(600))
        }
    }

    // MARK: 事件入口

    /// 键盘事件:返回 true 表示已处理。
    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        hideHover()
        if popup != nil, flags.isEmpty || flags == .shift {
            switch event.keyCode {
            case 126: popup?.moveSelection(-1); refreshFooter(); return true
            case 125: popup?.moveSelection(1); refreshFooter(); return true
            case 116: popup?.movePage(-1); refreshFooter(); return true
            case 121: popup?.movePage(1); refreshFooter(); return true
            case 36, 76: acceptPopup(); return true
            case 48 where flags.isEmpty: acceptPopup(); return true
            case 53: dismissPopup(); return true
            default: break
            }
        }
        if signatureCard != nil, event.keyCode == 53, flags.isEmpty { hideSignature(); return true }
        switch (event.keyCode, flags) {
        case (49, [.control]): triggerCompletion(auto: false); return true
        case (49, [.control, .shift]): triggerSignature(); return true
        case (47, [.command]): showCodeActions(); return true
        case (111, []): goToDefinition(); return true
        case (111, [.shift]): findReferences(); return true
        case (3, [.option, .shift]): formatDocument(); return true
        default: return false
        }
    }

    /// 用户输入了文本(单字符才会触发自动补全/签名/格式化)。
    func didInsert(_ text: String) {
        guard let view, text.count == 1, let character = text.first, view.composition == nil else { return }
        if services.onTypeTriggers.contains(character) { runOnTypeFormat(character) }
        if character == "(" || character == "," { triggerSignature() }
        if character == ")" { hideSignature() }
        guard services.completion != nil else { return }
        let isWord = character.isLetter || character.isNumber || character == "_" || character == "$"
        if services.completionTriggers.contains(character) {
            dismissPopup()
            scheduleAutoCompletion()
        } else if isWord, popup == nil {
            scheduleAutoCompletion()
        }
    }

    /// 文档变化:过滤补全、刷新签名、排队内嵌提示/语义刷新。
    func documentChanged() {
        hideHover()
        lastPreparedVersion = -1
        if case .completion? = popupMode { refilterCompletion() }
        if signatureCard != nil { scheduleSignatureUpdate() }
        scheduleRefresh(delay: .milliseconds(700))
    }

    /// 选区变化:关闭失效浮层并重新查询代码操作。
    func selectionChanged() {
        guard let view else { return }
        if case .completion? = popupMode {
            let head = view.model.selections.primary.head
            if head < popupAnchor || view.model.selections.isMulti { dismissPopup() }
        } else if popup != nil { dismissPopup() }
        if signatureCard != nil { scheduleSignatureUpdate() }
        scheduleCodeActions()
    }

    func mouseDown() {
        hideHover()
        if popup != nil { dismissPopup() }
        hideSignature()
    }

    func scrolled() {
        hideHover()
        repositionOverlays()
        scheduleRefresh(delay: .milliseconds(350), semantic: false)
    }

    /// 视图尺寸/折叠变化后重新摆放浮层。
    func repositionOverlays() {
        guard let view else { return }
        if let popup, popupMode != nil {
            let anchor = min(popupAnchor, view.model.document.length)
            place(popup, size: popup.frame.size, near: view.caretRect(forOffset: anchor))
        }
        if let card = signatureCard {
            place(card, size: card.frame.size, near: view.caretRect(forOffset: view.model.selections.primary.head), preferAbove: true)
        }
        layoutLightbulb()
    }

    // MARK: 补全

    private func scheduleAutoCompletion() {
        autoTriggerTask?.cancel()
        autoTriggerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self?.triggerCompletion(auto: true)
        }
    }

    /// 补全 / 签名等浮层是否正在显示。
    public var isPopupShown: Bool { popup != nil }

    /// 触发补全。
    /// - Parameter auto: 是否由输入自动触发(自动触发时不打扰:无结果静默)
    public func triggerCompletion(auto: Bool) {
        guard let view, let provider = services.completion, view.model.isEditable, !view.model.selections.isMulti else { return }
        prepare()
        completionGeneration += 1
        let generation = completionGeneration
        let offset = view.model.selections.primary.head
        let anchor = NativeCompletionMatcher.wordStart(before: offset, in: view.model.document.snapshot)
        let version = view.model.document.version
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let items = await provider(offset)
            guard let self, !Task.isCancelled, generation == self.completionGeneration, let view = self.view else { return }
            guard view.model.document.version >= version, view.model.selections.primary.head >= anchor else { return }
            guard !items.isEmpty else { if case .completion? = self.popupMode { self.dismissPopup() }; return }
            self.completionItems = items
            self.popupAnchor = items.compactMap { $0.replaceRange?.location }.min().map { min($0, anchor) } ?? anchor
            self.popupAnchor = min(self.popupAnchor, anchor)
            self.popupMode = .completion
            self.refilterCompletion()
        }
    }

    private func completionQuery() -> String {
        guard let view else { return "" }
        let head = view.model.selections.primary.head
        guard head >= popupAnchor else { return "" }
        return view.model.document.snapshot.string(in: TextSpan(location: popupAnchor, length: head - popupAnchor))
    }

    private func refilterCompletion() {
        guard let view, case .completion? = popupMode else { return }
        let head = view.model.selections.primary.head
        guard head >= popupAnchor else { dismissPopup(); return }
        completionFiltered = NativeCompletionMatcher.filter(completionItems, query: completionQuery())
        guard !completionFiltered.isEmpty else { dismissPopup(); return }
        let rows = completionFiltered.map {
            NativePopupRow(title: $0.item.label, detail: $0.item.detail, badge: $0.item.kind.badge, highlights: $0.indices)
        }
        let list = ensurePopup()
        list.rows = rows
        list.selected = 0
        list.footer = completionFiltered.first?.item.documentation.map(Self.firstLines)
        finishPopupLayout(list)
    }

    private func refreshFooter() {
        guard let popup, case .completion? = popupMode, popup.selected < completionFiltered.count else { return }
        popup.footer = completionFiltered[popup.selected].item.documentation.map(Self.firstLines)
        finishPopupLayout(popup)
    }

    private static func firstLines(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ")
        return String(cleaned.prefix(160))
    }

    private func acceptPopup() {
        guard let popup, let mode = popupMode else { return }
        let index = popup.selected
        switch mode {
        case .completion: acceptCompletion(at: index)
        case .actions(let items):
            guard items.indices.contains(index) else { return }
            let item = items[index]
            dismissPopup()
            Task { [weak self] in await self?.services.runCodeAction?(item) }
        case .locations(let items):
            guard items.indices.contains(index) else { return }
            dismissPopup()
            open(items[index])
        }
    }

    private func acceptCompletion(at index: Int) {
        guard let view, completionFiltered.indices.contains(index) else { return }
        let item = completionFiltered[index].item
        let head = view.model.selections.primary.head
        let span: TextSpan
        if let range = item.replaceRange, range.location <= head, NSMaxRange(range) >= head - 0 {
            span = TextSpan(location: range.location, length: max(max(NSMaxRange(range), head) - range.location, 0))
        } else {
            span = TextSpan(location: popupAnchor, length: max(head - popupAnchor, 0))
        }
        dismissPopup()
        completionTask?.cancel()
        if let snippet = item.snippet {
            view.model.insertSnippet(snippet, replacing: span)
        } else {
            view.model.insertText(item.insertText, replacing: span)
        }
        view.revealPrimaryCaret()
        if item.insertText.hasSuffix("(") { triggerSignature() }
    }

    // MARK: 浮层摆放

    private func ensurePopup() -> NativePopupListView {
        if let popup { return popup }
        let list = NativePopupListView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        list.onAccept = { [weak self] index in
            self?.popup?.selected = index
            self?.acceptPopup()
        }
        view?.addSubview(list)
        popup = list
        return list
    }

    private func finishPopupLayout(_ list: NativePopupListView) {
        guard let view else { return }
        let size = list.preferredSize(maxWidth: max(view.bounds.width - view.gutterWidth - 24, 200))
        let anchor = min(popupAnchor, view.model.document.length)
        place(list, size: size, near: view.caretRect(forOffset: anchor))
        list.needsDisplay = true
    }

    /// 把浮层摆在 `rect`(光标/字符矩形)附近:默认下方,放不下翻到上方;水平夹在视图内。
    private func place(_ child: NSView, size: CGSize, near rect: CGRect, preferAbove: Bool = false) {
        guard let view else { return }
        let bounds = view.bounds
        let below = rect.maxY + 2
        let above = rect.minY - size.height - 2
        var y = preferAbove ? above : below
        if preferAbove, above < 0 { y = below }
        if !preferAbove, below + size.height > bounds.height { y = above >= 0 ? above : max(bounds.height - size.height, 0) }
        let x = min(max(rect.minX - 2, view.gutterWidth), max(bounds.width - size.width - 4, view.gutterWidth))
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
        if child.frame != frame { child.frame = frame }
        child.isHidden = false
    }

    /// 关闭浮层列表。
    func dismissPopup() {
        popup?.removeFromSuperview()
        popup = nil
        popupMode = nil
        completionFiltered = []
        completionTask?.cancel()
        completionGeneration += 1
    }

    public var isCompletionVisible: Bool { popup != nil }

    // MARK: 悬停

    /// 鼠标移动:在单词上驻留一会儿后显示悬停卡片(诊断 + 服务器说明)。
    func mouseMoved(_ point: CGPoint) {
        guard let view else { return }
        if let card = hoverCard, card.frame.insetBy(dx: -6, dy: -6).contains(point) { return }
        guard point.x > view.gutterWidth, point.y >= 0, point.y < view.bounds.height, popup == nil else { hideHover(); return }
        let offset = view.offset(at: point)
        let rect = view.caretRect(forOffset: offset)
        guard abs(point.x - rect.minX) < view.cache.columnWidth * 1.6, point.y >= rect.minY, point.y <= rect.maxY else { hideHover(); return }
        let rope = view.model.document.snapshot
        let word = CursorMotion.wordRange(at: offset, in: rope)
        guard word.length > 0 else { hideHover(); return }
        if word == hoverWord { return }
        hideHover()
        hoverWord = word
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await self?.showHover(word: word, offset: min(max(offset, word.location), word.upperBound))
        }
    }

    func mouseExited(_ point: CGPoint) {
        if let card = hoverCard, card.frame.insetBy(dx: -6, dy: -6).contains(point) { return }
        hideHover()
    }

    private func showHover(word: TextSpan, offset: Int) async {
        guard let view, hoverWord == word else { return }
        var content = NSMutableAttributedString()
        let diagnostics = view.model.decorations.containing(offset: offset).filter {
            switch $0.kind {
            case .diagnosticError, .diagnosticWarning, .diagnosticInfo, .diagnosticHint: true
            default: false
            }
        }
        let mono = view.font
        for item in diagnostics {
            guard let message = item.payload else { continue }
            let color: Color = item.kind == .diagnosticError ? OMColors.danger : (item.kind == .diagnosticWarning ? OMColors.warning : OMColors.accent)
            content.append(NSAttributedString(string: message + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12 * OMScale.ui), .foregroundColor: NSColor(color),
            ]))
        }
        if let hover = services.hover {
            prepare()
            if let text = await hover(offset), !text.isEmpty {
                guard hoverWord == word else { return }
                if content.length > 0 { content.append(NSAttributedString(string: "\n")) }
                content.append(NativeInfoCardView.render(markdown: text, monoFont: mono))
            }
        }
        // 先去掉首尾空白与换行再判断:空诊断消息、空 Markdown 渲染出的纯空白不能弹出一张空卡片
        let whitespace = CharacterSet.whitespacesAndNewlines
        while let last = content.string.unicodeScalars.last, whitespace.contains(last) {
            content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
        }
        while let first = content.string.unicodeScalars.first, whitespace.contains(first) {
            content.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        guard hoverWord == word, content.length > 0 else { return }
        let card = hoverCard ?? NativeInfoCardView(frame: .zero)
        let size = card.setContent(content)
        if card.superview == nil { view.addSubview(card) }
        hoverCard = card
        place(card, size: size, near: view.caretRect(forOffset: word.location), preferAbove: true)
    }

    /// 调试钩子:直接在某偏移显示悬停卡片(无需真实鼠标)。
    public func debugShowHover(at offset: Int) {
        guard let view else { return }
        let word = CursorMotion.wordRange(at: offset, in: view.model.document.snapshot)
        hoverWord = word
        Task { [weak self] in await self?.showHover(word: word, offset: offset) }
    }

    func hideHover() {
        hoverTask?.cancel()
        hoverCard?.removeFromSuperview()
        hoverCard = nil
        hoverWord = nil
    }

    // MARK: 签名

    public func triggerSignature() {
        guard let view, let provider = services.signatureHelp else { return }
        prepare()
        signatureTask?.cancel()
        let offset = view.model.selections.primary.head
        signatureTask = Task { [weak self] in
            let help = await provider(offset)
            guard let self, !Task.isCancelled, let view = self.view else { return }
            guard let help else { self.hideSignature(); return }
            let card = self.signatureCard ?? NativeInfoCardView(frame: .zero)
            let size = card.setContent(NativeInfoCardView.render(signature: help.label, activeParameter: help.activeParameter, monoFont: view.font))
            if card.superview == nil { view.addSubview(card) }
            self.signatureCard = card
            self.place(card, size: size, near: view.caretRect(forOffset: view.model.selections.primary.head), preferAbove: true)
        }
    }

    private func scheduleSignatureUpdate() {
        signatureTask?.cancel()
        signatureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.triggerSignature()
        }
    }

    func hideSignature() {
        signatureTask?.cancel()
        signatureCard?.removeFromSuperview()
        signatureCard = nil
    }

    // MARK: 定义与引用

    /// 跳转定义。
    /// - Parameter offset: 目标偏移,nil 取主光标
    public func goToDefinition(at offset: Int? = nil) {
        guard let view, let provider = services.definition else { return }
        prepare()
        let target = offset ?? view.model.selections.primary.head
        Task { [weak self] in
            let locations = await provider(target)
            guard let self else { return }
            self.presentLocations(locations)
        }
    }

    /// 查找引用并以列表浮层展示。
    public func findReferences() {
        guard let view, let provider = services.references else { return }
        prepare()
        let target = view.model.selections.primary.head
        Task { [weak self] in
            let locations = await provider(target)
            self?.presentLocations(locations, forceList: true)
        }
    }

    private func presentLocations(_ locations: [NativeLocation], forceList: Bool = false) {
        guard let view, !locations.isEmpty else { return }
        if locations.count == 1, !forceList { open(locations[0]); return }
        let rows = locations.map { location in
            NativePopupRow(title: location.preview.isEmpty ? (location.path as NSString).lastPathComponent : location.preview.trimmingCharacters(in: .whitespaces),
                           detail: "\((location.path as NSString).lastPathComponent):\(location.line + 1)", badge: nil)
        }
        dismissPopup()
        popupMode = .locations(locations)
        popupAnchor = view.model.selections.primary.head
        let list = ensurePopup()
        list.maxVisible = 12
        list.rows = rows
        list.selected = 0
        list.footer = nil
        finishPopupLayout(list)
    }

    /// 打开一个位置:同文件直接跳转,跨文件交给宿主。
    func open(_ location: NativeLocation) {
        guard let view else { return }
        let current = view.model.fileName.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if current == URL(fileURLWithPath: location.path).standardizedFileURL.path {
            let rope = view.model.document.snapshot
            let line = min(max(location.line, 0), max(rope.lineCount - 1, 0))
            let range = rope.lineRange(line) ?? TextSpan(location: 0, length: 0)
            let target = range.location + min(max(location.column, 0), range.length)
            view.model.setSelections(SelectionSet(caret: target))
            view.scrollToLine(line)
            view.window?.makeFirstResponder(view)
        } else {
            services.openLocation?(location)
        }
    }

    // MARK: 代码操作与灯泡

    private func scheduleCodeActions() {
        codeActionTask?.cancel()
        guard let view, let provider = services.codeActions, view.model.isEditable else { hideLightbulb(); return }
        let range = view.model.selections.primary.range
        codeActionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let view = self.view else { return }
            self.prepare()
            let actions = await provider(NSRange(location: range.location, length: range.length))
            guard !Task.isCancelled, view.model.selections.primary.range == range else { return }
            self.availableActions = actions
            if actions.isEmpty { self.hideLightbulb() } else { self.showLightbulb(quickFix: actions.contains { $0.isQuickFix }) }
        }
    }

    private func showLightbulb(quickFix: Bool) {
        guard let view else { return }
        let bulb = lightbulb ?? NativeLightbulbView(frame: .zero)
        bulb.isQuickFix = quickFix
        bulb.onClick = { [weak self] in self?.showCodeActions() }
        if bulb.superview == nil { view.addSubview(bulb) }
        lightbulb = bulb
        layoutLightbulb()
    }

    private func layoutLightbulb() {
        guard let view, let bulb = lightbulb else { return }
        let rect = view.caretRect(forOffset: view.model.selections.primary.head)
        bulb.frame = CGRect(x: 2, y: rect.minY, width: 16, height: rect.height)
        bulb.isHidden = rect.maxY < 0 || rect.minY > view.bounds.height
    }

    private func hideLightbulb() {
        lightbulb?.removeFromSuperview()
        lightbulb = nil
        availableActions = []
    }

    /// 弹出代码操作列表(⌘. 或点击灯泡)。
    public func showCodeActions() {
        guard let view, let provider = services.codeActions else { return }
        let range = view.model.selections.primary.range
        prepare()
        Task { [weak self] in
            guard let self else { return }
            let actions = await provider(NSRange(location: range.location, length: range.length))
            guard !actions.isEmpty else { return }
            self.dismissPopup()
            self.popupMode = .actions(actions)
            self.popupAnchor = range.location
            let list = self.ensurePopup()
            list.maxVisible = 9
            list.rows = actions.map { NativePopupRow(title: $0.title, detail: nil, badge: $0.isQuickFix ? "!" : "✦") }
            list.selected = 0
            list.footer = nil
            self.finishPopupLayout(list)
        }
    }

    // MARK: 格式化

    /// 格式化整个文档,或存在选区时只格式化选区。
    public func formatDocument() {
        guard let view, let provider = services.format, view.model.isEditable else { return }
        prepare()
        let primary = view.model.selections.primary.range
        let range: NSRange? = primary.isEmpty ? nil : NSRange(location: primary.location, length: primary.length)
        let version = view.model.document.version
        Task { [weak self] in
            let edits = await provider(range)
            guard let self, let view = self.view, view.model.document.version == version else { return }
            view.model.applyTextEdits(edits)
        }
    }

    private func runOnTypeFormat(_ character: Character) {
        guard let view, let provider = services.onTypeFormat else { return }
        prepare()
        let offset = view.model.selections.primary.head
        let version = view.model.document.version
        Task { [weak self] in
            let edits = await provider(offset, character)
            guard let self, let view = self.view, view.model.document.version == version, !edits.isEmpty else { return }
            view.model.applyTextEdits(edits, coalesceKey: "typing")
        }
    }

    // MARK: 内嵌提示与语义着色

    private func scheduleRefresh(delay: Duration, semantic: Bool = true) {
        if services.inlayHints != nil {
            inlayTask?.cancel()
            inlayTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.refreshInlays()
            }
        }
        if semantic, services.semanticSpans != nil {
            semanticTask?.cancel()
            semanticTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.refreshSemantic()
            }
        }
    }

    private func refreshInlays() async {
        guard let view, let provider = services.inlayHints else { return }
        prepare()
        let version = view.model.document.version
        let visible = view.visibleOffsetRange()
        let rope = view.model.document.snapshot
        let span = max(visible.length, 2_000)
        let range = NSRange(location: max(visible.location - span / 2, 0), length: min(visible.length + span, rope.length - max(visible.location - span / 2, 0)))
        let hints = await provider(range)
        guard !Task.isCancelled, view.model.document.version == version else { return }
        let decorations = hints.prefix(2_000).enumerated().map { index, hint in
            Decoration(id: inlayDecorationBase + index, range: TextSpan(location: min(max(hint.offset, 0), rope.length), length: 0),
                       kind: .inlay, payload: hint.label, removesWhenCollapsed: false)
        }
        view.model.decorations.replace(kinds: [.inlay], with: decorations)
        view.model.hasInlays = !decorations.isEmpty
        view.cache.clear()
        view.needsDisplay = true
    }

    private func refreshSemantic() async {
        guard let view, let provider = services.semanticSpans else { return }
        prepare()
        let version = view.model.document.version
        let spans = await provider()
        guard !Task.isCancelled, view.model.document.version == version else { return }
        let length = view.model.document.length
        var list: [Decoration] = []
        list.reserveCapacity(spans.count)
        for (index, span) in spans.enumerated() where span.range.location >= 0 && NSMaxRange(span.range) <= length && span.range.length > 0 {
            list.append(Decoration(id: semanticDecorationBase + index, range: TextSpan(location: span.range.location, length: span.range.length),
                                   kind: .custom(nativeSemanticBase + Int(span.kind.rawValue)), payload: nil, removesWhenCollapsed: true))
        }
        view.model.decorations.replace(kinds: Self.semanticKinds, with: list)
        view.model.hasSemantic = !list.isEmpty
        view.cache.clear()
        view.needsDisplay = true
    }

    private static let semanticKinds: Set<DecorationKind> = Set((0..<16).map { DecorationKind.custom(nativeSemanticBase + $0) })

    private func clearDecorations() {
        guard let view else { return }
        view.model.decorations.replace(kinds: [.inlay], with: [])
        view.model.decorations.replace(kinds: Self.semanticKinds, with: [])
        view.model.hasInlays = false
        view.model.hasSemantic = false
        view.cache.clear()
        view.needsDisplay = true
    }

    /// 视图销毁:取消所有后台任务。
    func teardown() {
        completionTask?.cancel(); autoTriggerTask?.cancel(); hoverTask?.cancel(); signatureTask?.cancel()
        codeActionTask?.cancel(); inlayTask?.cancel(); semanticTask?.cancel()
    }
}
