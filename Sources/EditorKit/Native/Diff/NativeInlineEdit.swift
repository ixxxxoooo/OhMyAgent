// @author ixxxxoooo
// ⌘K 行内编辑:在选区上方弹出指令输入卡片(View Zone),交给外部提供的生成闭包,
// 结果直接写入文档并以行内 Diff 呈现,⌘⏎ 接受、Esc 拒绝(拒绝时把选区恢复为原文)。

import AppKit
import DesignSystem
import DiffKit
import EditorCore
import OMLog

/// 行内编辑的生成闭包:参数依次为 指令、选中文本、选区前上下文、选区后上下文;返回替换文本。
public typealias NativeInlineEditGenerator = @MainActor (_ instruction: String, _ selected: String, _ before: String, _ after: String) async throws -> String

/// 指令输入卡片。
@MainActor
final class NativeInlineEditCard: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let submitButton = NativeDiffActionButton(title: String(localized: "生成 ⏎"))
    private let cancelButton = NativeDiffActionButton(title: String(localized: "取消 Esc"))
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12.5 * OMScale.ui)
        field.textColor = NSColor(OMColors.primaryText)
        field.placeholderString = String(localized: "描述要如何修改选中的代码…")
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "行内编辑指令"))
        status.font = NSFont.systemFont(ofSize: 11 * OMScale.ui)
        status.textColor = NSColor(OMColors.secondaryText)
        status.lineBreakMode = .byTruncatingTail
        submitButton.onClick = { [weak self] in self?.submit() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        for view in [field, status, submitButton, cancelButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// 展示状态文字(生成中 / 错误);`busy` 时禁用输入。
    func show(status text: String, isError: Bool = false, busy: Bool) {
        status.stringValue = text
        status.textColor = NSColor(isError ? OMColors.danger : OMColors.secondaryText)
        field.isEnabled = !busy
        submitButton.isHidden = busy
    }

    private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let cancelWidth = cancelButton.preferredWidth, submitWidth = submitButton.isHidden ? 0 : submitButton.preferredWidth
        var right = bounds.width - 8
        cancelButton.frame = NSRect(x: right - cancelWidth, y: 4, width: cancelWidth, height: 22)
        right -= cancelWidth + 2
        if submitWidth > 0 {
            submitButton.frame = NSRect(x: right - submitWidth, y: 4, width: submitWidth, height: 22)
            right -= submitWidth + 2
        }
        field.frame = NSRect(x: inset, y: 5, width: max(right - inset - 8, 40), height: 20)
        status.frame = NSRect(x: inset, y: 30, width: max(bounds.width - inset * 2, 40), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(OMColors.subtleFill).setFill()
        bounds.fill()
        NSColor(OMColors.hairline).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        NSColor(OMColors.accent).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// ⌘K 行内编辑控制器(每个编辑器视图一个)。
@MainActor
public final class NativeInlineEdit {
    /// 生成闭包由外部提供;为 nil 时 ⌘K 不拦截(交还给全局搜索等)。
    public var generate: NativeInlineEditGenerator?

    /// 阶段。
    public enum Phase: Equatable, Sendable {
        case idle, prompting, generating, reviewing
    }

    public private(set) var phase: Phase = .idle
    private static let zoneID = 0x4100_0000
    private static let cardHeight: Double = 50
    private weak var view: OMEditorView?
    private var card: NativeInlineEditCard?
    private var task: Task<Void, Never>?
    /// 目标范围(UTF-16);审阅阶段为替换后的范围。
    private var range = TextSpan(location: 0, length: 0)
    private var startLine = 0
    private var originalText = ""
    private var applying = false

    init(view: OMEditorView) { self.view = view }

    /// 是否可用(已接入生成闭包且编辑器可编辑)。
    public var isAvailable: Bool { generate != nil && view?.model.isEditable == true }

    // MARK: 流程

    /// 开始:以当前选区(扩展到整行;无选区取光标所在行)为目标弹出输入卡片。
    public func begin() {
        guard let view, isAvailable else { return }
        if phase == .reviewing { accept() }
        guard phase == .idle else { return }
        let rope = view.model.document.snapshot
        let selection = view.model.selections.primary.range
        let first = rope.line(containing: selection.location)
        var last = rope.line(containing: selection.upperBound)
        // 选区终点恰在下一行行首时不把那一行算进去。
        if selection.length > 0, last > first, rope.lineStart(last) == selection.upperBound { last -= 1 }
        startLine = first
        range = TextSpan(location: rope.lineStart(first), length: rope.lineStart(last) + rope.lineLength(last) - rope.lineStart(first))
        guard range.length <= InlineEditLimits.maxSelectionLength else {
            Log.editor.info("行内编辑选区过大,已忽略", ["length": "\(range.length)"])
            return
        }
        let card = NativeInlineEditCard(frame: .zero)
        card.onSubmit = { [weak self] text in self?.submit(text) }
        card.onCancel = { [weak self] in self?.cancel() }
        self.card = card
        phase = .prompting
        view.model.setZones(view.model.zones.filter { $0.id != Self.zoneID } + [ViewZone(id: Self.zoneID, afterLine: first - 1, height: Self.cardHeight)])
        view.setZoneView(card, forZone: Self.zoneID)
        highlightTarget(true)
        view.scrollToLine(max(first - 1, 0), centered: false)
        view.window?.makeFirstResponder(card.field)
    }

    /// 调试 / 自动化:以给定指令直接走完「开始 → 提交」(`OMA_IDE_EDITOR_ACTIONS` 的 `inline:` 使用)。
    /// - Parameter instruction: 指令文本
    public func debugRun(_ instruction: String) {
        begin()
        guard phase == .prompting, let card else { return }
        card.field.stringValue = instruction
        submit(instruction)
    }

    private func submit(_ instruction: String) {
        guard phase == .prompting, let view, let generate, let card else { return }
        let rope = view.model.document.snapshot
        let selected = rope.string(in: range)
        let beforeStart = rope.lineStart(max(startLine - 20, 0))
        let before = rope.string(in: TextSpan(location: beforeStart, length: max(range.location - beforeStart, 0)))
        let afterLine = rope.line(containing: range.upperBound)
        let afterStart = min(range.upperBound + 1, rope.length)
        let afterEnd = min(rope.lineStart(min(afterLine + 20, rope.lineCount - 1)) + rope.lineLength(min(afterLine + 20, rope.lineCount - 1)), rope.length)
        let after = afterEnd > afterStart ? rope.string(in: TextSpan(location: afterStart, length: afterEnd - afterStart)) : ""
        phase = .generating
        card.show(status: String(localized: "正在生成…"), busy: true)
        task = Task { [weak self] in
            do {
                let output = try await generate(instruction, selected, before, after)
                guard !Task.isCancelled else { return }
                self?.apply(output, original: selected)
            } catch {
                guard !Task.isCancelled else { return }
                Log.editor.warning("行内编辑生成失败", ["error": "\(error)"])
                self?.phase = .prompting
                card.show(status: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true, busy: false)
                self?.view?.window?.makeFirstResponder(card.field)
            }
        }
    }

    /// 把生成结果写入文档并进入审阅。
    private func apply(_ output: String, original: String) {
        guard phase == .generating, let view else { return }
        var text = output
        // 选区不含末尾换行时,模型多带的一个结尾换行去掉,避免凭空多出空行。
        if text.hasSuffix("\n"), !original.hasSuffix("\n") { text.removeLast() }
        originalText = original
        removeCard()
        highlightTarget(false)
        applying = true
        defer { applying = false }
        do {
            try view.model.document.apply([DocumentEdit(range: range, text: text)], selectionsBefore: view.model.selections.selections,
                                          selectionsAfter: [Selection(caret: range.location)], coalesceKey: nil)
        } catch {
            Log.editor.error("行内编辑写入文档失败", ["error": "\(error)"])
            phase = .idle
            return
        }
        range = TextSpan(location: range.location, length: (text as NSString).length)
        view.model.setSelections(SelectionSet(caret: range.location))
        phase = .reviewing
        let diff = LineDiff.diff(old: original, new: text)
        if diff.isEmpty {
            // 模型认为无需修改:直接结束。
            finish()
            return
        }
        let actions = [NativeDiffAction(title: String(localized: "接受 ⌘⏎")) { [weak self] _ in self?.accept() },
                       NativeDiffAction(title: String(localized: "拒绝 Esc")) { [weak self] _ in self?.reject() }]
        view.inlineReview.show(diff: diff, lineOffset: startLine, title: { _ in String(localized: "AI 行内编辑") }, actions: actions)
        view.window?.makeFirstResponder(view)
        view.scrollToLine(max(startLine - 1, 0), centered: false)
    }

    /// 接受修改(保留文档里的新内容)。
    public func accept() {
        guard phase == .reviewing else { return }
        finish()
    }

    /// 拒绝修改:把范围恢复成原文。
    public func reject() {
        guard phase == .reviewing, let view else { return }
        applying = true
        defer { applying = false }
        do {
            try view.model.document.apply([DocumentEdit(range: range, text: originalText)], selectionsBefore: view.model.selections.selections,
                                          selectionsAfter: [Selection(caret: range.location)], coalesceKey: nil)
        } catch {
            Log.editor.error("行内编辑还原失败", ["error": "\(error)"])
        }
        finish()
    }

    /// 取消(输入或生成阶段)。
    public func cancel() {
        switch phase {
        case .prompting, .generating:
            task?.cancel()
            task = nil
            removeCard()
            highlightTarget(false)
            phase = .idle
            view?.window?.makeFirstResponder(view)
        case .reviewing: reject()
        case .idle: break
        }
    }

    private func finish() {
        view?.inlineReview.clear()
        phase = .idle
        view?.window?.makeFirstResponder(view)
    }

    /// 审阅期间用户继续编辑文档:视为接受(范围已不可靠)。
    func documentDidChange() {
        if phase == .reviewing, !applying { finish() }
    }

    /// 编辑器键盘钩子:审阅阶段 ⌘⏎ 接受、Esc 拒绝;空闲阶段 ⌘K 开始(仅可用时)。
    func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (phase, event.keyCode, flags) {
        case (.reviewing, 36, [.command]): accept(); return true
        case (.reviewing, 53, []): reject(); return true
        default: return false
        }
    }

    // MARK: 辅助

    private func removeCard() {
        guard let view else { return }
        view.setZoneView(nil, forZone: Self.zoneID)
        view.model.setZones(view.model.zones.filter { $0.id != Self.zoneID })
        card = nil
    }

    /// 输入阶段给目标行加底色。
    private func highlightTarget(_ on: Bool) {
        guard let view else { return }
        view.model.decorations.removeAll { $0.id >= Self.zoneID && $0.id < Self.zoneID + 0x1000 }
        guard on else { view.needsDisplay = true; return }
        let rope = view.model.document.snapshot
        let last = rope.line(containing: range.upperBound)
        var id = Self.zoneID
        for line in startLine...max(last, startLine) where line < rope.lineCount {
            view.model.decorations.insert(Decoration(id: id, range: TextSpan(location: rope.lineStart(line), length: rope.lineLength(line)),
                                                     kind: .agentModified, removesWhenCollapsed: false))
            id += 1
        }
        view.needsDisplay = true
    }
}

/// 行内编辑的限制(纯常量,EditorKit 内不依赖 ChatKit)。
enum InlineEditLimits {
    static let maxSelectionLength = 12_000
}
