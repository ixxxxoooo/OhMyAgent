// @author ixxxxoooo
// 输入框:基于 AppKit NSTextView(TextKit 2),支持 Return 发送、Shift+Return 换行、输入法组合态保护、
// 自动增高与占位文字。比 SwiftUI TextEditor 更可控,且不会在输入法组合期间误触发发送。

import AppKit
import DesignSystem
import ChatKit
import OMLog
import SwiftUI

/// 补全弹层的按键。
enum CompletionKey { case up, down, accept, dismiss }

/// 输入框控制器:让外部(补全弹层)替换文本。
@MainActor
final class ComposerController {
    weak var textView: SubmitTextView?

    /// 让文本视图成为第一响应者(视图刚出现时文本视图可能还没挂上窗口,稍等一帧再试)。
    func focus() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let textView = self?.textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// 在当前选区处插入文本(与前一个字符粘连时自动补一个空格),光标落在插入内容之后。
    /// - Parameter string: 要插入的文本
    func insertAtSelection(_ string: String) {
        guard let textView, !string.isEmpty else { return }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        var text = string
        if selection.location > 0, selection.location <= ns.length {
            let previous = ns.character(at: selection.location - 1)
            if let scalar = Unicode.Scalar(previous), !CharacterSet.whitespacesAndNewlines.contains(scalar) { text = " " + text }
        }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: selection)
    }

    /// 替换指定范围的文本,光标落在替换内容之后。
    /// - Parameters:
    ///   - range: UTF-16 范围
    ///   - string: 新文本
    func replace(range: NSRange, with string: String) {
        guard let textView else { return }
        // 补全上下文基于纯文本坐标(提及按 `@路径` 全长计),这里换算到文本存储坐标
        let storage = textView.storageRange(forPlain: range)
        guard NSMaxRange(storage) <= (textView.string as NSString).length else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: storage)
    }
}

/// 提交型文本视图。
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    /// 补全弹层是否可见(可见时拦截方向键/Return/Tab/Esc)
    var isCompletionActive: () -> Bool = { false }
    var onCompletionKey: ((CompletionKey) -> Void)?
    /// Shift+Tab
    var onBacktab: (() -> Void)?
    /// ⌘Return:运行中排到本轮结束后发送
    var onSubmitAfterTurn: (() -> Void)?
    /// 粘贴/拖入图片;返回 true 表示已处理
    var onImages: (([ImageAttachment]) -> Void)?
    /// 是否接受图片(Agent 不支持图片时不接管粘贴)
    var acceptsImages: () -> Bool = { false }
    /// 粘贴/拖入非图片文件或文件夹:由外部转成 `@路径` 提及
    var onFileURLs: (([URL]) -> Void)?
    var placeholder: String = "" { didSet { refreshPlaceholder() } }
    /// 工作区目录:非 nil 时,草稿里已存在的 `@路径` 会显示成内联 chip
    var mentionWorkspace: URL?

    /// 只接受纯文字(附件由我们自己管理),避免粘贴/拖入富文本。
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// 复制:附件还原成 `@路径` 纯文本。
    override func copy(_ sender: Any?) { writePlainSelection() }

    /// 剪切:同复制,再删除选区。
    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        writePlainSelection()
        insertText("", replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if !hasMarkedText() {
            if isCompletionActive(), modifiers.isEmpty {
                switch event.keyCode {
                case 126: onCompletionKey?(.up); return
                case 125: onCompletionKey?(.down); return
                case 36, 76, 48: onCompletionKey?(.accept); return
                case 53: onCompletionKey?(.dismiss); return
                default: break
                }
            }
            if event.keyCode == 48, modifiers == [.shift], let onBacktab {
                onBacktab()
                return
            }
        }
        if isReturn, !hasMarkedText() {
            // 发送键偏好:⌘Return 发送模式下,Return 换行、⌘Return 正常发送
            let commandToSend = ClientPrefs.sendKey() == .commandEnter
            if modifiers.isEmpty {
                if commandToSend { insertNewlineIgnoringFieldEditor(nil) } else { onSubmit?() }
                return
            }
            if modifiers == [.command] {
                if commandToSend { onSubmit?() } else { onSubmitAfterTurn?() }
                return
            }
            if modifiers == [.shift] || modifiers == [.option] {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
        if event.keyCode == 53, !hasMarkedText(), let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    /// 粘贴:剪贴板含图片时作为附件,含文件/文件夹时转成 `@路径`,否则按纯文本粘贴。
    override func paste(_ sender: Any?) {
        if handlePasteboard(.general) { return }
        super.pasteAsPlainText(sender)
    }

    /// 「粘贴并匹配样式」(⌥⇧⌘V)同样要支持图片与文件,与 `paste(_:)` 共用一套逻辑。
    override func pasteAsPlainText(_ sender: Any?) {
        if handlePasteboard(.general) { return }
        super.pasteAsPlainText(sender)
    }

    /// 处理粘贴板里的图片/文件。
    /// - Parameter board: 粘贴板
    /// - Returns: 已处理返回 true;false 表示交给文本视图按文字粘贴
    func handlePasteboard(_ board: NSPasteboard) -> Bool {
        if acceptsImages(), ImageIntake.prefersImage(board) {
            let images = ImageIntake.attachments(from: board)
            if !images.isEmpty {
                onImages?(images)
                // 同一次粘贴里的非图片文件也一并引用
                let others = ImageIntake.nonImageFileURLs(from: board)
                if !others.isEmpty { onFileURLs?(others) }
                return true
            }
            // 识别为图片却解码失败:不要悄悄粘成空文本,提示并记录
            Log.ui.warning("粘贴图片失败:无法解码剪贴板里的图片", ["types": board.types?.map(\.rawValue).joined(separator: ",") ?? ""])
            if (board.string(forType: .string) ?? "").isEmpty {
                NSSound.beep()
                return true
            }
        }
        let files = ImageIntake.nonImageFileURLs(from: board)
        if !files.isEmpty, onFileURLs != nil {
            onFileURLs?(files)
            return true
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        if acceptsImages(), ImageIntake.hasImage(board) { return .copy }
        if onFileURLs != nil, ImageIntake.hasFileURLs(board) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        var handled = false
        if acceptsImages(), ImageIntake.hasImage(board) {
            let images = ImageIntake.attachments(from: board)
            if !images.isEmpty {
                onImages?(images)
                handled = true
            }
        }
        if onFileURLs != nil {
            let files = ImageIntake.nonImageFileURLs(from: board)
            if !files.isEmpty {
                onFileURLs?(files)
                handled = true
            }
        }
        return handled ? true : super.performDragOperation(sender)
    }

    // MARK: 占位文字

    /// 占位文字标签:独立子视图而非在 `draw` 里手绘。
    /// 手绘方案在输入法组合期间(拼音 `fen` 还是 marked text)只会重绘组合区域,旧占位像素残留,与拼音叠在一起;
    /// 子视图用 `isHidden` 切换,不依赖脏区重绘。
    private lazy var placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .placeholderTextColor
        label.setAccessibilityElement(false)
        addSubview(label)
        return label
    }()

    /// 占位文字当前是否可见(测试用)。
    var isPlaceholderVisible: Bool { !placeholderLabel.isHidden }

    /// 按「无文本且无输入法组合文本」刷新占位标签的内容、位置与显隐。
    func refreshPlaceholder() {
        let label = placeholderLabel
        let showing = string.isEmpty && !hasMarkedText() && !placeholder.isEmpty
        label.isHidden = !showing
        guard showing else { return }
        label.stringValue = placeholder
        label.font = font ?? NSFont.systemFont(ofSize: 13.5)
        let originX = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: originX, y: textContainerInset.height, width: max(bounds.width - originX - 4, 0), height: size.height)
    }

    override func layout() {
        super.layout()
        refreshPlaceholder()
    }

    override func didChangeText() {
        super.didChangeText()
        refreshPlaceholder()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshPlaceholder()
    }

    override func unmarkText() {
        super.unmarkText()
        refreshPlaceholder()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        refreshPlaceholder()
    }

    /// 命中测试忽略占位标签,点击落到文本视图本身。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === placeholderLabel ? self : hit
    }
}

/// 输入框的 SwiftUI 封装。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var maxHeight: CGFloat = 220
    var onSubmit: () -> Void
    var onEscape: (() -> Void)?
    var controller: ComposerController?
    var isCompletionActive: () -> Bool = { false }
    var onCompletionKey: ((CompletionKey) -> Void)?
    var onBacktab: (() -> Void)?
    var onSubmitAfterTurn: (() -> Void)?
    var onImages: (([ImageAttachment]) -> Void)?
    var acceptsImages: () -> Bool = { false }
    var onFileURLs: (([URL]) -> Void)?
    /// 文本或光标变化(未处于输入法组合态时)
    var onEdit: ((String, Int) -> Void)?
    /// 选中文字变化(无选中为 nil)
    var onSelectionText: ((String?) -> Void)?
    /// 工作区目录:传入后,草稿里已存在的 `@路径` 显示为内联 chip
    var mentionWorkspace: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.drawsBackground = false
        // 富文本模式只为容纳内联 chip 附件;粘贴/复制都已改成纯文本,见 SubmitTextView
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.onSubmit = { [coordinator = context.coordinator] in coordinator.parent.onSubmit() }
        textView.onEscape = { [coordinator = context.coordinator] in coordinator.parent.onEscape?() }
        textView.isCompletionActive = { [coordinator = context.coordinator] in coordinator.parent.isCompletionActive() }
        textView.onCompletionKey = { [coordinator = context.coordinator] key in coordinator.parent.onCompletionKey?(key) }
        textView.onBacktab = { [coordinator = context.coordinator] in coordinator.parent.onBacktab?() }
        textView.onSubmitAfterTurn = { [coordinator = context.coordinator] in coordinator.parent.onSubmitAfterTurn?() }
        textView.onImages = { [coordinator = context.coordinator] images in coordinator.parent.onImages?(images) }
        textView.acceptsImages = { [coordinator = context.coordinator] in coordinator.parent.acceptsImages() }
        textView.onFileURLs = { [coordinator = context.coordinator] urls in coordinator.parent.onFileURLs?(urls) }
        textView.registerForDraggedTypes([.fileURL] + ImageIntake.acceptedTypes.map { NSPasteboard.PasteboardType($0.identifier) })
        textView.setAccessibilityLabel(String(localized: "消息输入框"))
        controller?.textView = textView

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        scrollView.syncTabActive(context.environment.tabIsActive)
        textView.mentionWorkspace = mentionWorkspace
        if textView.plainText != text, !textView.hasMarkedText() {
            // 外部整体赋值(发送清空、补全、引用选区、重新编辑):按纯文本重建,光标落到末尾
            let end = (text as NSString).length
            textView.setContent(plain: text, allowTrailingEnd: true, selection: NSRange(location: end, length: 0))
        }
        textView.placeholder = placeholder
        textView.refreshPlaceholder()
        context.coordinator.updateHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: SubmitTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            let range = textView.selectedRange()
            parent.onSelectionText?(range.length > 0 ? textView.plainText(in: range) : nil)
            parent.onEdit?(textView.plainText, textView.plainSelection.location)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // 先把「后面已跟空白」的提及换成 chip,再回写纯文本
            textView.reconcileMentions()
            let plain = textView.plainText
            if parent.text != plain { parent.text = plain }
            updateHeight()
        }

        /// chip 与相邻文字之间自动补空格:否则紧贴 chip 输入会让记号变形(`@a.swiftx`),chip 被打回文字。
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let box = textView as? SubmitTextView, let replacement = replacementString, !replacement.isEmpty,
                  !box.hasMarkedText(), let first = replacement.first, let last = replacement.last else { return true }
            let length = (box.string as NSString).length
            var text = replacement
            if affectedCharRange.location > 0, box.isMention(at: affectedCharRange.location - 1), !first.isWhitespace { text = " " + text }
            if NSMaxRange(affectedCharRange) < length, box.isMention(at: NSMaxRange(affectedCharRange)), !last.isWhitespace { text += " " }
            guard text != replacement else { return true }
            box.insertText(text, replacementRange: affectedCharRange)
            return false
        }

        /// 根据内容计算高度并回写。
        func updateHeight() {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return }
            layoutManager.ensureLayout(for: contentManager.documentRange)
            let used = layoutManager.usageBoundsForTextContainer.height
            let target = min(max(used + textView.textContainerInset.height * 2, 34), parent.maxHeight)
            if abs(parent.height - target) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.parent.height = target }
            }
            textView.enclosingScrollView?.hasVerticalScroller = used + textView.textContainerInset.height * 2 > parent.maxHeight
        }
    }
}
