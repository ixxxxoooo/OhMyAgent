// @author ygw
// 输入框:基于 AppKit NSTextView(TextKit 2),支持 Return 发送、Shift+Return 换行、输入法组合态保护、
// 自动增高与占位文字。比 SwiftUI TextEditor 更可控,且不会在输入法组合期间误触发发送。

import AppKit
import DesignSystem
import ChatKit
import SwiftUI

/// 补全弹层的按键。
enum CompletionKey { case up, down, accept, dismiss }

/// 输入框控制器:让外部(补全弹层)替换文本。
@MainActor
final class ComposerController {
    weak var textView: SubmitTextView?

    /// 替换指定范围的文本,光标落在替换内容之后。
    /// - Parameters:
    ///   - range: UTF-16 范围
    ///   - string: 新文本
    func replace(range: NSRange, with string: String) {
        guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: range)
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
    var placeholder: String = "" { didSet { needsDisplay = true } }

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

    /// 粘贴:剪贴板含图片时作为附件,否则按纯文本粘贴。
    override func paste(_ sender: Any?) {
        if acceptsImages(), ImageIntake.hasImage(.general) {
            let images = ImageIntake.attachments(from: .general)
            if !images.isEmpty {
                onImages?(images)
                return
            }
        }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptsImages(), ImageIntake.hasImage(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if acceptsImages(), ImageIntake.hasImage(sender.draggingPasteboard) {
            let images = ImageIntake.attachments(from: sender.draggingPasteboard)
            if !images.isEmpty {
                onImages?(images)
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
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
    /// 文本或光标变化(未处于输入法组合态时)
    var onEdit: ((String, Int) -> Void)?
    /// 选中文字变化(无选中为 nil)
    var onSelectionText: ((String?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.drawsBackground = false
        textView.isRichText = false
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
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.setAccessibilityLabel("消息输入框")
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
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        textView.placeholder = placeholder
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
            parent.onSelectionText?(range.length > 0 ? (textView.string as NSString).substring(with: range) : nil)
            parent.onEdit?(textView.string, textView.selectedRange().location)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            updateHeight()
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
