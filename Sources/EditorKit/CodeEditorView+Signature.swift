// @author ixxxxoooo
// 签名帮助:输入 `(` 或 `,` 后向语言服务器请求,在光标下方显示签名并高亮当前参数;
// 光标离开未闭合的括号(或输入 `)`)时自动收起。

import AppKit
import DesignSystem

/// 签名帮助触发规则(纯函数,便于测试)。
public enum EditorSignatureTrigger {
    /// 光标前一个字符是否应触发请求(`(` 或 `,`)。
    /// - Parameters:
    ///   - text: 全文
    ///   - caret: 光标 UTF-16 偏移
    public static func shouldRequest(in text: String, caret: Int) -> Bool {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return false }
        let char = ns.character(at: caret - 1)
        return char == 0x28 || char == 0x2C
    }

    /// 光标前是否存在尚未闭合的 `(`(最多向前扫描 `limit` 个字符,忽略字符串内的括号不做处理,保持简单)。
    /// - Parameters:
    ///   - text: 全文
    ///   - caret: 光标 UTF-16 偏移
    ///   - limit: 向前扫描的上限
    public static func hasUnclosedParen(in text: String, caret: Int, limit: Int = 2_000) -> Bool {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return false }
        var depth = 0
        var index = caret - 1
        let stop = max(caret - limit, 0)
        while index >= stop {
            switch ns.character(at: index) {
            case 0x29: depth += 1
            case 0x28:
                if depth == 0 { return true }
                depth -= 1
            default: break
            }
            index -= 1
        }
        return false
    }

    /// 把签名渲染为带当前参数高亮的富文本。
    /// - Parameters:
    ///   - signature: 签名
    ///   - font: 等宽字体
    ///   - normal: 普通文字色
    ///   - highlight: 当前参数色
    public static func attributed(_ signature: EditorSignature, font: NSFont, normal: NSColor, highlight: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: signature.label, attributes: [.font: font, .foregroundColor: normal])
        if let range = signature.activeParameter, NSMaxRange(range) <= (signature.label as NSString).length {
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            result.addAttributes([.font: bold, .foregroundColor: highlight, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return result
    }
}

extension CodeEditorView {
    /// 文本变化后更新签名帮助:触发字符 → 请求并显示;括号已闭合 → 收起;其余保持现状。
    func updateSignatureHelp() {
        guard let provider = features.signatureHelp else { return }
        let text = textView.string
        let caret = textView.selectedRange().location
        guard EditorSignatureTrigger.hasUnclosedParen(in: text, caret: caret) else {
            closeSignatureHelp()
            return
        }
        guard EditorSignatureTrigger.shouldRequest(in: text, caret: caret) || signaturePopover != nil else { return }
        signatureGeneration += 1
        let generation = signatureGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.signatureGeneration == generation else { return }
            let signature = await provider(caret)
            guard self.signatureGeneration == generation, self.textView.selectedRange().location == caret else { return }
            if let signature { self.presentSignature(signature, caret: caret) } else { self.closeSignaturePopover() }
        }
    }

    /// 收起签名帮助(并使在途请求作废)。
    func closeSignatureHelp() {
        signatureGeneration += 1
        closeSignaturePopover()
    }

    private func presentSignature(_ signature: EditorSignature, caret: Int) {
        var actual = NSRange(location: 0, length: 0)
        let screen = textView.firstRect(forCharacterRange: NSRange(location: max(caret - 1, 0), length: 1), actualRange: &actual)
        guard screen != .zero, let window = textView.window else { return }
        let rect = textView.convert(window.convertFromScreen(screen), from: nil)
        let label = NSTextField(labelWithAttributedString: EditorSignatureTrigger.attributed(
            signature, font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            normal: NSColor(OMColors.secondaryText), highlight: NSColor(OMColors.accentText)
        ))
        label.isSelectable = false
        label.setAccessibilityLabel(signature.label)
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        let controller = NSViewController()
        controller.view = content
        closeSignaturePopover()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        signaturePopover = popover
        popover.show(relativeTo: rect, of: textView, preferredEdge: .minY)
    }

    private func closeSignaturePopover() {
        signaturePopover?.close()
        signaturePopover = nil
    }
}
