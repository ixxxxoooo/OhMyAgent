// @author ixxxxoooo
// 编辑器的语言智能扩展点(EditorKit 不依赖 LSPKit):诊断、悬停、跳转定义、补全。
// 应用层把 LSP 结果转换成这里的轻量类型并通过回调注入。

import AppKit

/// 编辑器内的一条诊断。偏移单位为 UTF-16(与 NSRange 一致)。
public struct EditorDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable, Equatable {
        case error = 1, warning, information, hint
    }

    public var range: NSRange
    public var severity: Severity
    public var message: String

    /// - Parameters:
    ///   - range: 受影响的文本范围
    ///   - severity: 严重程度
    ///   - message: 诊断文案
    public init(range: NSRange, severity: Severity, message: String) {
        self.range = range
        self.severity = severity
        self.message = message
    }
}

/// 一个补全候选。
public struct EditorCompletion: Sendable, Equatable {
    public var label: String
    /// 实际插入的文本
    public var insertText: String

    public init(label: String, insertText: String) {
        self.label = label
        self.insertText = insertText
    }
}

/// 签名帮助:函数签名文本与当前参数的范围。
public struct EditorSignature: Sendable, Equatable {
    /// 完整签名,如 `f(a: Int, b: String)`
    public var label: String
    /// 当前参数在 `label` 里的 UTF-16 范围
    public var activeParameter: NSRange?

    public init(label: String, activeParameter: NSRange? = nil) {
        self.label = label
        self.activeParameter = activeParameter
    }
}

/// 语言智能回调集合。所有回调都在主线程调用,偏移为 UTF-16 偏移。
public struct EditorLanguageFeatures {
    /// 悬停:返回要展示的文本,无信息返回 nil。
    public var hover: (@MainActor (_ offset: Int) async -> String?)?
    /// 跳转定义(⌘ 点击或 F12)。
    public var definition: (@MainActor (_ offset: Int) -> Void)?
    /// 补全候选(⌃Space / Esc,或输入 `.` 后自动触发)。
    public var completion: (@MainActor (_ offset: Int) async -> [EditorCompletion])?
    /// 签名帮助(输入 `(` 或 `,` 后自动触发):返回当前调用的签名,没有返回 nil。
    public var signatureHelp: (@MainActor (_ offset: Int) async -> EditorSignature?)?

    public init(
        hover: (@MainActor (_ offset: Int) async -> String?)? = nil,
        definition: (@MainActor (_ offset: Int) -> Void)? = nil,
        completion: (@MainActor (_ offset: Int) async -> [EditorCompletion])? = nil,
        signatureHelp: (@MainActor (_ offset: Int) async -> EditorSignature?)? = nil
    ) {
        self.hover = hover
        self.definition = definition
        self.completion = completion
        self.signatureHelp = signatureHelp
    }
}

/// 代码编辑器使用的文本视图:增加鼠标悬停驻留、⌘ 点击、F12 与异步补全。
@MainActor
public final class EditorTextView: NSTextView {
    /// 鼠标在某字符上驻留:(UTF-16 偏移, 该字符在视图坐标中的矩形)
    var onHoverDwell: ((Int, NSRect) -> Void)?
    /// 鼠标离开字符/视图或开始输入、滚动。
    var onHoverEnd: (() -> Void)?
    /// ⌘ 点击或 F12:请求跳转定义
    var onJumpToDefinition: ((Int) -> Void)?
    /// 异步取补全候选
    var completionProvider: ((Int) async -> [EditorCompletion])?
    /// 「在对话中引用选区」:传入非空选区的 UTF-16 范围
    var onReferenceSelection: ((NSRange) -> Void)?

    /// 额外的空光标(UTF-16 偏移):AppKit 的 `selectedRanges` 会把多个空光标塌缩成一个,
    /// 因此除主选区外的空光标由我们自己保存与绘制;普通选区变化/外部编辑会清空它。
    var secondaryCarets: [Int] = [] {
        didSet { if oldValue != secondaryCarets { needsDisplay = true } }
    }
    /// 当前行末的内联提示(如 Git blame):入参为光标偏移,返回要显示的文字;nil 不显示
    var inlineNote: ((Int) -> String?)? {
        didSet { needsDisplay = true }
    }
    /// 鼠标悬停所在行的行首偏移(内联提示也显示在悬停行;鼠标离开为 nil)
    var hoverNoteLineStart: Int? {
        didSet { if oldValue != hoverNoteLineStart, inlineNote != nil { needsDisplay = true } }
    }
    /// 正在应用多光标编辑(此时选区/文本变化不应清空额外光标)
    var isApplyingMultiEdit = false

    /// 当前语言(决定行注释前缀、缩进单位与自动缩进规则)
    var language: SyntaxLanguage = .plain
    /// 是否启用代码编辑增强(自动缩进、自动闭合、行操作快捷键);只读或 Markdown 就地渲染时由宿主关闭
    var codeEditingEnabled = true
    /// ⌃G:请求「转到行」(由宿主弹出输入)
    var onGoToLine: (() -> Void)?
    /// 当前行高亮色(nil 不画)
    var currentLineColor: NSColor?
    /// 括号匹配高亮的偏移(UTF-16,最多两个);由宿主在选区变化时更新
    var bracketPair: [Int] = [] { didSet { if oldValue != bracketPair { needsDisplay = true } } }
    /// 括号匹配高亮色
    var bracketColor: NSColor?

    /// 获得/失去键盘焦点(Markdown 就地渲染据此决定是否展开光标所在块)
    var onFocusChange: ((Bool) -> Void)?

    /// 当前是否启用 Markdown 所见即所得交互(任务框点击、⌘ 点击链接、列表续行)
    var markdownInteraction: (() -> Bool)?
    /// 最近一次与文本一致的 Markdown 块布局(用于避开围栏代码里的伪任务框);可能为 nil
    var markdownLayout: (() -> MarkdownLiveLayout?)?

    /// 是否启用 Markdown 交互。
    private var markdownInteractive: Bool { markdownInteraction?() ?? false }

    /// 应用一次 Markdown 编辑:走标准的「询问 → 替换 → 通知」流程,撤销栈与文本回调都正常工作。
    private func apply(_ edit: MarkdownEdit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(NSRange(location: edit.caret, length: 0))
    }

    /// 应用一次通用文本编辑(撤销栈正常工作)。
    func applyEdit(_ edit: TextEdit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        let length = (string as NSString).length
        let location = min(max(edit.selection.location, 0), length)
        setSelectedRange(NSRange(location: location, length: min(edit.selection.length, length - location)))
        scrollRangeToVisible(selectedRange())
    }

    /// 是否可以走单光标的代码编辑增强(可编辑、开启、无输入法组合、只有一个选区)。
    private var canEnhance: Bool {
        isEditable && codeEditingEnabled && !hasMarkedText() && selectionCount == 1
    }

    /// 一级缩进:Tab 字符缩进的文件用制表符,否则按语言取 2 或 4 个空格。
    private var indentUnit: String {
        if string.utf8.count < 200_000, string.contains("\n\t") { return "\t" }
        return EditorEditing.indentUnit(for: language)
    }

    /// 列表项末尾回车:续出下一项,空项回车结束列表;代码文件沿用/增加缩进。
    public override func insertNewline(_ sender: Any?) {
        if isMultiCursor, language != .markdown {
            multiNewline(unit: indentUnit)
            return
        }
        if isEditable, markdownInteractive, !hasMarkedText(),
           let edit = MarkdownEditCommands.continueList(in: string, selection: selectedRange()) {
            apply(edit)
            return
        }
        if canEnhance, language != .markdown, language != .plain {
            let selection = selectedRange()
            let result = EditorEditing.newline(text: string, caret: selection.location, unit: indentUnit, language: language)
            applyEdit(TextEdit(range: selection, replacement: result.insertion,
                               selection: NSRange(location: selection.location + result.caret, length: 0)))
            return
        }
        super.insertNewline(sender)
    }

    /// 输入字符:括号/引号自动闭合、闭合符跨越、选区包裹。
    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if isMultiCursor, replacementRange.location == NSNotFound {
            if let text = insertString as? String { multiInsert(text); return }
            if let attributed = insertString as? NSAttributedString { multiInsert(attributed.string); return }
        }
        if canEnhance, language != .markdown, language != .plain, replacementRange.location == NSNotFound,
           let text = insertString as? String, text.count == 1, let char = text.first,
           EditorBehaviorPrefs.autoClose,
           let edit = EditorEditing.typed(char, text: string, selection: selectedRange()) {
            if edit.replacement.isEmpty {
                setSelectedRange(edit.selection)
            } else {
                applyEdit(edit)
            }
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// 退格:夹在空括号对之间时一并删除。
    public override func deleteBackward(_ sender: Any?) {
        if isMultiCursor {
            multiDeleteBackward()
            return
        }
        if canEnhance, language != .markdown, language != .plain, EditorBehaviorPrefs.autoClose,
           let edit = EditorEditing.backspacePair(text: string, selection: selectedRange()) {
            applyEdit(edit)
            return
        }
        super.deleteBackward(sender)
    }

    /// Tab:多行选区整体缩进。
    public override func insertTab(_ sender: Any?) {
        if isMultiCursor {
            multiInsert(indentUnit)
            return
        }
        if canEnhance, spansMultipleLines, let edit = EditorEditing.indent(text: string, selection: selectedRange(), outdent: false, unit: indentUnit) {
            applyEdit(edit)
            return
        }
        super.insertTab(sender)
    }

    /// ⇧Tab:反缩进当前行/选中行。
    public override func insertBacktab(_ sender: Any?) {
        if canEnhance, let edit = EditorEditing.indent(text: string, selection: selectedRange(), outdent: true, unit: indentUnit) {
            applyEdit(edit)
            return
        }
        super.insertBacktab(sender)
    }

    /// 选区是否跨越多行。
    private var spansMultipleLines: Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let ns = string as NSString
        return ns.lineRange(for: range).length > ns.lineRange(for: NSRange(location: range.location, length: 0)).length
            || (ns.substring(with: range) as NSString).contains("\n")
    }

    /// 当前行高亮与括号匹配高亮(在文字之下绘制)。
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let manager = textLayoutManager, let storage = textContentStorage else { return }
        let origin = textContainerOrigin
        if let color = currentLineColor, isEditable, EditorBehaviorPrefs.currentLine, selectionCount == 1, selectedRange().length == 0,
           window?.firstResponder === self,
           let location = storage.location(storage.documentRange.location, offsetBy: selectedRange().location),
           let fragment = manager.textLayoutFragment(for: location) {
            var frame = fragment.layoutFragmentFrame
            frame.origin.y += origin.y
            frame.origin.x = 0
            frame.size.width = bounds.width
            color.setFill()
            frame.intersection(rect).fill()
        }
        if let color = bracketColor, !bracketPair.isEmpty, EditorBehaviorPrefs.bracketMatch {
            color.setFill()
            for offset in bracketPair {
                guard let start = storage.location(storage.documentRange.location, offsetBy: offset),
                      let end = storage.location(start, offsetBy: 1),
                      let range = NSTextRange(location: start, end: end) as NSTextRange? else { continue }
                manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                    var box = frame
                    box.origin.x += origin.x
                    box.origin.y += origin.y
                    NSBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: 0), xRadius: 2, yRadius: 2).fill()
                    return true
                }
            }
        }
    }

    // MARK: 行操作与多光标

    /// 执行一个行操作快捷键;返回是否已处理。
    private func handleEditingShortcut(_ event: NSEvent, isKeyEquivalent: Bool) -> Bool {
        guard canEnhance || (isEditable && codeEditingEnabled && selectionCount > 1 && event.keyCode == 2) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, flags) {
        case (44, [.command]): perform(.toggleComment)
        case (40, [.command, .shift]): perform(.deleteLine)
        case (126, [.option]): perform(.moveLineUp)
        case (125, [.option]): perform(.moveLineDown)
        case (126, [.option, .shift]): perform(.duplicateLineUp)
        case (125, [.option, .shift]): perform(.duplicateLineDown)
        case (2, [.command]) where isKeyEquivalent: perform(.addNextOccurrence)
        case (5, [.control]):  // ⌃G 转到行
            guard let onGoToLine else { return false }
            onGoToLine()
        default: return false
        }
        return true
    }

    /// 执行一个编辑动作(快捷键与命令面板共用)。
    /// - Parameter action: 动作
    func perform(_ action: EditorAction) {
        guard isEditable, codeEditingEnabled else { return }
        let selection = selectedRange()
        switch action {
        case .toggleComment:
            guard selectionCount == 1, let prefix = EditorEditing.commentPrefix(for: language),
                  let edit = EditorEditing.toggleLineComment(text: string, selection: selection, prefix: prefix) else { return }
            applyEdit(edit)
        case .deleteLine:
            guard selectionCount == 1 else { return }
            applyEdit(EditorEditing.deleteLines(text: string, selection: selection))
        case .moveLineUp, .moveLineDown:
            guard selectionCount == 1,
                  let edit = EditorEditing.moveLines(text: string, selection: selection, up: action == .moveLineUp) else { return }
            applyEdit(edit)
        case .duplicateLineUp, .duplicateLineDown:
            guard selectionCount == 1 else { return }
            applyEdit(EditorEditing.duplicateLines(text: string, selection: selection, down: action == .duplicateLineDown))
        case .addNextOccurrence:
            addNextOccurrence()
        case .fold, .unfold, .foldAll, .unfoldAll:
            break  // 视图级动作,由 `CodeEditorView.perform` 处理
        }
    }

    /// ⌘D:无选区时先选中光标处的单词;有选区时把下一处相同文本加入选区(到末尾后回绕)。
    func addNextOccurrence() {
        let ns = string as NSString
        var ranges = selectedRanges.map(\.rangeValue)
        guard let last = ranges.last else { return }
        if last.length == 0 {
            let word = ns.rangeOfWord(at: last.location)
            guard word.length > 0 else { return }
            setSelectedRange(word)
            return
        }
        let needle = ns.substring(with: last)
        var searchStart = NSMaxRange(last)
        for _ in 0..<2 {
            let found = ns.range(of: needle, options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
            if found.location != NSNotFound, !ranges.contains(found) {
                ranges.append(found)
                setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
                scrollRangeToVisible(found)
                return
            }
            searchStart = 0
        }
    }


    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isApplyingMultiEdit, !secondaryCarets.isEmpty { secondaryCarets = [] }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    public override func didChangeText() {
        if !isApplyingMultiEdit, !secondaryCarets.isEmpty { secondaryCarets = [] }
        super.didChangeText()
    }

    public override func moveLeft(_ sender: Any?) {
        if isMultiCursor { multiMove(by: -1); return }
        super.moveLeft(sender)
    }

    public override func moveRight(_ sender: Any?) {
        if isMultiCursor { multiMove(by: 1); return }
        super.moveRight(sender)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSecondaryCarets(in: dirtyRect)
        drawInlineNote(in: dirtyRect)
    }

    public override func deleteForward(_ sender: Any?) {
        if isMultiCursor {
            multiDeleteForward()
            return
        }
        super.deleteForward(sender)
    }

    public override func paste(_ sender: Any?) {
        if isMultiCursor {
            multiPaste()
            return
        }
        super.paste(sender)
    }

    /// Esc:多光标时收回成单光标,否则交给默认处理(补全等)。
    public override func cancelOperation(_ sender: Any?) {
        if selectionCount > 1 {
            collapseMultiCursor()
            return
        }
        super.cancelOperation(sender)
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    private var dwellTask: Task<Void, Never>?
    private var hoverOffset: Int?
    private var pendingCompletions: [EditorCompletion] = []
    private var completionTask: Task<Void, Never>?
    private static let dwellDelay: Duration = .milliseconds(450)

    // MARK: 悬停

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.options.contains(.mouseMoved) { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if inlineNote != nil { updateHoverNoteLine(at: point) }
        guard onHoverDwell != nil else { return }
        guard let (offset, rect) = characterUnder(point) else {
            cancelHover()
            return
        }
        if hoverOffset == offset { return }
        cancelHover()
        hoverOffset = offset
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwellDelay)
            guard !Task.isCancelled, let self, self.hoverOffset == offset else { return }
            self.onHoverDwell?(offset, rect)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverNoteLineStart = nil
        cancelHover()
    }

    public override func scrollWheel(with event: NSEvent) {
        hoverNoteLineStart = nil
        cancelHover()
        super.scrollWheel(with: event)
    }

    /// 取消待触发的悬停并通知关闭悬浮窗。
    func cancelHover() {
        dwellTask?.cancel()
        dwellTask = nil
        if hoverOffset != nil {
            hoverOffset = nil
            onHoverEnd?()
        }
    }

    /// 视图坐标下鼠标所在的字符;位于行尾空白或文本之外返回 nil。
    private func characterUnder(_ point: NSPoint) -> (Int, NSRect)? {
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let insertion = characterIndexForInsertion(at: point)
        // 插入点位于字符边界:鼠标在字符左半边得到 c,右半边得到 c+1,两者都检查
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            guard let rect = rectOfCharacter(candidate), rect.insetBy(dx: -1, dy: 0).contains(point) else { continue }
            let char = (string as NSString).character(at: candidate)
            if let scalar = Unicode.Scalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            return (candidate, rect)
        }
        return nil
    }

    private func rectOfCharacter(_ index: Int) -> NSRect? {
        var actual = NSRange(location: 0, length: 0)
        let screen = firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: &actual)
        guard let window, screen != .zero else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return convert(inWindow, from: nil)
    }

    // MARK: 跳转定义

    public override func mouseDown(with event: NSEvent) {
        // ⌥ 点击:在点击处增加一个光标
        if isEditable, codeEditingEnabled, event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command),
           let (offset, _) = characterUnder(convert(event.locationInWindow, from: nil)) {
            addCaret(at: offset)
            return
        }
        if markdownInteractive, handleMarkdownClick(event) { return }
        if event.modifierFlags.contains(.command), onJumpToDefinition != nil {
            let point = convert(event.locationInWindow, from: nil)
            if let (offset, _) = characterUnder(point) {
                onJumpToDefinition?(offset)
                return
            }
        }
        cancelHover()
        super.mouseDown(with: event)
    }

    /// Markdown 点击:⌘ 点击链接用系统默认方式打开;单击任务框切换勾选。
    /// - Returns: 事件是否已被消费
    private func handleMarkdownClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let target = MarkdownEditCommands.linkTarget(in: string, at: offset),
           let url = URL(string: target), let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme.lowercased()) {
            NSWorkspace.shared.open(url)
            return true
        }
        if isEditable, flags.isEmpty, event.clickCount == 1,
           let edit = MarkdownEditCommands.toggleTask(in: string, at: offset, layout: markdownLayout?()) {
            apply(edit)
            return true
        }
        return false
    }

    public override func keyDown(with event: NSEvent) {
        cancelHover()
        if handleEditingShortcut(event, isKeyEquivalent: false) { return }
        // F12:跳转到光标处符号的定义
        if event.keyCode == 111, let jump = onJumpToDefinition {
            jump(selectedRange().location)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: 引用选区

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if onReferenceSelection != nil, selectedRange().length > 0, let menu {
            let item = NSMenuItem(title: String(localized: "在对话中引用选区"), action: #selector(referenceSelection(_:)), keyEquivalent: "L")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func referenceSelection(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        onReferenceSelection?(range)
    }

    /// ⌘⇧L:引用选区(无选区或未接入时交还系统处理)。
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, handleEditingShortcut(event, isKeyEquivalent: true) { return true }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "l",
           onReferenceSelection != nil, selectedRange().length > 0, window?.firstResponder === self {
            referenceSelection(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 补全

    /// 先异步向语言服务器取候选,拿到后再走系统补全菜单。
    public override func complete(_ sender: Any?) {
        guard let provider = completionProvider else {
            super.complete(sender)
            return
        }
        completionTask?.cancel()
        let caret = selectedRange().location
        completionTask = Task { [weak self] in
            let items = await provider(caret)
            guard !Task.isCancelled, let self, !items.isEmpty, self.selectedRange().location == caret else { return }
            self.pendingCompletions = items
            self.presentSystemCompletion(sender)
        }
    }

    /// 调用系统补全菜单(闭包内不能直接使用 `super`,故单独封装)。
    private func presentSystemCompletion(_ sender: Any?) { super.complete(sender) }

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard !pendingCompletions.isEmpty else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        let ns = string as NSString
        let prefix = charRange.length > 0 && NSMaxRange(charRange) <= ns.length ? ns.substring(with: charRange).lowercased() : ""
        index.pointee = 0
        return Self.menuStrings(for: pendingCompletions, prefix: prefix)
    }

    /// 按已输入前缀(忽略大小写)过滤并去重,返回补全菜单要显示的文本(即将插入的文本),最多 60 项。
    /// - Parameters:
    ///   - items: 候选
    ///   - prefix: 已输入的前缀
    public static func menuStrings(for items: [EditorCompletion], prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        return items
            .filter { lowered.isEmpty || $0.label.lowercased().hasPrefix(lowered) }
            .map(\.insertText)
            .filter { seen.insert($0).inserted }
            .prefix(60)
            .map { $0 }
    }
}

private extension NSString {
    /// 光标处(或紧邻)的单词范围(字母、数字、下划线);没有返回长度 0。
    func rangeOfWord(at offset: Int) -> NSRange {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < length, let scalar = UnicodeScalar(character(at: index)) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        var start = offset
        var end = offset
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

/// 编辑器可被外部(命令面板、菜单)触发的编辑动作。
public enum EditorAction: Sendable {
    case toggleComment, deleteLine, moveLineUp, moveLineDown, duplicateLineUp, duplicateLineDown, addNextOccurrence
    /// 折叠/展开(视图级动作,只读文件也可用)
    case fold, unfold, foldAll, unfoldAll
}
