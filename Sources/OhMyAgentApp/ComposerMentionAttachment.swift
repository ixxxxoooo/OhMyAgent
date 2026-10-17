// @author ixxxxoooo
// 输入框内联文件 chip:文本存储里每个提及是一个 `NSTextAttachment`(1 个 UTF-16 单元),
// 由 `NSTextAttachmentViewProvider` 渲染成与原来一样的 `FileMentionChip`;草稿仍是带 `@路径` 的纯文本。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 一个文件提及附件。
final class MentionAttachment: NSTextAttachment {
    /// 对应的提及(含 `@` 与引号的原始记号)
    let mention: FileMention

    /// - Parameter mention: 提及
    init(mention: FileMention) {
        self.mention = mention
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = MentionViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

/// 把提及附件渲染成 SwiftUI chip 的视图提供者(TextKit 总在主线程调用)。
final class MentionViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        // TextKit 总在主线程调用;基类方法被导入为 nonisolated,这里显式断言主线程以满足严格并发
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? MentionAttachment else { return }
            let remove: () -> Void = { [weak provider] in provider?.removeFromText() }
            let host = NSHostingView(rootView: FileMentionChip(mention: attachment.mention, onRemove: remove, compact: true, removeOnHover: true))
            host.setFrameSize(host.fittingSize)
            provider.view = host
        }
    }

    /// 悬停 × 时把这颗 chip 从输入框删除(并通知草稿同步)。
    @MainActor
    fileprivate func removeFromText() {
        guard let manager = textLayoutManager,
              let textView = manager.textContainer?.textView as? SubmitTextView,
              let attachment = textAttachment as? MentionAttachment else { return }
        let offset = manager.offset(from: manager.documentRange.location, to: location)
        textView.removeMention(attachment, near: offset)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        nonisolated(unsafe) let provider = self
        let size: CGSize = MainActor.assumeIsolated {
            if provider.view == nil { provider.loadView() }
            return provider.view?.frame.size ?? .zero
        }
        // 向下偏移,让 chip 与文字基线视觉居中
        return CGRect(x: 0, y: -5, width: size.width, height: size.height)
    }
}

// MARK: - 输入框文本存储与纯文本互转

extension SubmitTextView {
    /// 文本存储里的全部提及附件(按位置升序)。
    var mentionAttachments: [(location: Int, attachment: MentionAttachment)] {
        guard let storage = textStorage else { return [] }
        var result: [(Int, MentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? MentionAttachment { result.append((range.location, attachment)) }
        }
        return result.map { (location: $0.0, attachment: $0.1) }
    }

    /// 附件位置换算用的跨度表。
    var mentionSpans: [ComposerMentionLayout.Span] {
        mentionAttachments.map { ComposerMentionLayout.Span(storageLocation: $0.location, tokenLength: ($0.attachment.mention.token as NSString).length) }
    }

    /// 草稿纯文本:附件还原成 `@路径` 记号。
    var plainText: String { plainText(in: NSRange(location: 0, length: (string as NSString).length)) }

    /// 文本存储某范围对应的纯文本。
    /// - Parameter range: 文本存储中的 UTF-16 范围
    /// - Returns: 附件还原为记号后的文字
    func plainText(in range: NSRange) -> String {
        let ns = string as NSString
        guard NSMaxRange(range) <= ns.length else { return "" }
        var result = ""
        var cursor = range.location
        for item in mentionAttachments where item.location >= range.location && item.location < NSMaxRange(range) {
            result += ns.substring(with: NSRange(location: cursor, length: item.location - cursor))
            result += item.attachment.mention.token
            cursor = item.location + 1
        }
        result += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        return result
    }

    /// 当前光标/选区(纯文本坐标)。
    var plainSelection: NSRange {
        let spans = mentionSpans
        let selection = selectedRange()
        let start = ComposerMentionLayout.plainOffset(storage: selection.location, spans: spans)
        let end = ComposerMentionLayout.plainOffset(storage: NSMaxRange(selection), spans: spans)
        return NSRange(location: start, length: end - start)
    }

    /// 纯文本范围 → 文本存储范围。
    /// - Parameter plain: 纯文本中的 UTF-16 范围
    /// - Returns: 文本存储中的范围
    func storageRange(forPlain plain: NSRange) -> NSRange {
        let spans = mentionSpans
        let start = ComposerMentionLayout.storageOffset(plain: plain.location, spans: spans)
        var end = ComposerMentionLayout.storageOffset(plain: NSMaxRange(plain), spans: spans)
        // 结束点落在记号内部时吸附到附件之后,避免只替换半个 chip
        if let hit = spans.first(where: { $0.storageLocation == end }) {
            let chipStart = ComposerMentionLayout.plainOffset(storage: end, spans: spans)
            if NSMaxRange(plain) > chipStart, NSMaxRange(plain) < chipStart + hit.tokenLength { end = hit.storageLocation + 1 }
        }
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// 删除一颗内联 chip。优先按提供者给出的位置;位置不可信时按附件对象查找。
    /// - Parameters:
    ///   - attachment: 要删除的提及附件
    ///   - near: 期望所在的文本存储位置
    func removeMention(_ attachment: MentionAttachment, near offset: Int) {
        let target: Int
        if isMention(at: offset), (textStorage?.attribute(.attachment, at: offset, effectiveRange: nil) as? MentionAttachment) === attachment {
            target = offset
        } else if let found = mentionAttachments.first(where: { $0.attachment === attachment }) {
            target = found.location
        } else {
            return
        }
        let range = NSRange(location: target, length: 1)
        guard shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
    }

    /// 指定存储位置是否是提及附件。
    /// - Parameter location: 文本存储中的 UTF-16 位置
    func isMention(at location: Int) -> Bool {
        guard let storage = textStorage, location >= 0, location < storage.length else { return false }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) is MentionAttachment
    }

    /// 用纯文本整体重建文本存储:存在的 `@路径` 变成内联 chip。
    /// - Parameters:
    ///   - plain: 草稿纯文本
    ///   - allowTrailingEnd: 末尾的提及是否也变成 chip
    ///   - selection: 重建后的选区(纯文本坐标)
    func setContent(plain: String, allowTrailingEnd: Bool, selection: NSRange) {
        let pieces = mentionWorkspace.map {
            ComposerMentionLayout.pieces(for: plain, workspace: $0, allowTrailingEnd: allowTrailingEnd)
        } ?? (plain.isEmpty ? [] : [.text(plain)])
        let baseFont = font ?? NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor(OMColors.primaryText)]
        let result = NSMutableAttributedString()
        for piece in pieces {
            switch piece {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attributes))
            case .mention(let mention):
                let chip = NSMutableAttributedString(attachment: MentionAttachment(mention: mention))
                chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
                result.append(chip)
            }
        }
        textStorage?.setAttributedString(result)
        typingAttributes = attributes
        let clamped = NSRange(
            location: min(selection.location, (plain as NSString).length),
            length: min(selection.length, max((plain as NSString).length - selection.location, 0))
        )
        setSelectedRange(storageRange(forPlain: clamped))
    }

    /// 编辑后核对:纯文本里「后面已跟空白」的提及要变成 chip,附件对应的路径被改坏则还原为文字。
    func reconcileMentions() {
        guard !hasMarkedText(), mentionWorkspace != nil else { return }
        let existing = mentionAttachments
        let plain = plainText
        guard plain.contains("@") || !existing.isEmpty else { return }
        let endChipExists = isMention(at: (string as NSString).length - 1)
        let desired = ComposerMentionLayout.pieces(for: plain, workspace: mentionWorkspace ?? URL(fileURLWithPath: "/"), allowTrailingEnd: endChipExists)
            .compactMap { piece -> String? in
                if case .mention(let mention) = piece { return mention.token }
                return nil
            }
        guard desired != existing.map(\.attachment.mention.token) else { return }
        setContent(plain: plain, allowTrailingEnd: endChipExists, selection: plainSelection)
    }

    /// 把选区的纯文本写入剪贴板(附件还原成 `@路径`)。
    func writePlainSelection() {
        let range = selectedRange()
        guard range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(in: range), forType: .string)
    }
}
