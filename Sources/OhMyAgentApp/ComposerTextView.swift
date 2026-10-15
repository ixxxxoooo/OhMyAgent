// @author ygw
// 输入框:基于 AppKit NSTextView(TextKit 2),支持 Return 发送、Shift+Return 换行、输入法组合态保护、
// 自动增高与占位文字。比 SwiftUI TextEditor 更可控,且不会在输入法组合期间误触发发送。

import AppKit
import SwiftUI

/// 提交型文本视图。
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if isReturn, !hasMarkedText() {
            if modifiers.isEmpty {
                onSubmit?()
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
        textView.setAccessibilityLabel("消息输入框")

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
