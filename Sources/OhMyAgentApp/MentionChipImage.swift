// @author ixxxxoooo
// 时间线用户消息里的文件引用 chip:把输入框同款的 `FileMentionChip` 渲染成静态图,
// 供 TextKit 1 的只读叶子(附件图片)与吸顶卡(行内 Text 图片)使用;存储仍是纯文本 `@路径`。

import AppKit
import ChatKit
import DesignSystem
import SwiftUI

/// 文件提及 chip 图片与富文本构造。
@MainActor
enum MentionChipImage {
    /// 缓存键:记号 + 样式(字号、主题修订、深浅色),样式变化后自然失效
    private struct Key: Hashable {
        let token: String
        let style: OMLeafStyle
    }

    private static var cache: [Key: NSImage] = [:]

    /// 渲染某个提及的 chip 图片(同样式下复用缓存)。
    /// - Parameter mention: 文件提及
    /// - Returns: chip 图片(尺寸为点);渲染失败返回 nil
    static func image(for mention: FileMention) -> NSImage? {
        let key = Key(token: mention.token, style: .current)
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: FileMentionChip(mention: mention, compact: true))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// 带 chip 的富文本:提及段是 1 个附件字符(记录复制文本与路径),其余是普通文字。
    /// - Parameters:
    ///   - pieces: 草稿切分片段(`ComposerMentionLayout.pieces`)
    ///   - attributes: 文字段的属性(字体、颜色、段落样式)
    /// - Returns: 富文本;复制时附件还原为 `@路径` 记号
    static func attributedString(pieces: [ComposerMentionLayout.Piece], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in pieces {
            switch piece {
            case .text(let text):
                result.append(NSAttributedString(string: text, attributes: attributes))
            case .mention(let mention):
                guard let image = image(for: mention) else {
                    result.append(NSAttributedString(string: mention.token, attributes: attributes))
                    continue
                }
                let attachment = NSTextAttachment()
                attachment.image = image
                // 向下偏移,让 chip 与文字基线视觉居中(与输入框内联 chip 一致)
                attachment.bounds = CGRect(x: 0, y: -5, width: image.size.width, height: image.size.height)
                let chip = NSMutableAttributedString(attachment: attachment)
                var chipAttributes = attributes
                chipAttributes[OMReadOnlyTextView.copyTextKey] = mention.token
                if !mention.isDirectory { chipAttributes[OMReadOnlyTextView.mentionPathKey] = mention.path }
                chip.addAttributes(chipAttributes, range: NSRange(location: 0, length: chip.length))
                result.append(chip)
            }
        }
        return result
    }

    /// 吸顶卡用的行内 Text:提及用 chip 图片,其余是文字。
    /// - Parameters:
    ///   - pieces: 草稿切分片段
    ///   - font: 文字字体
    /// - Returns: 拼接后的 Text
    static func inlineText(pieces: [ComposerMentionLayout.Piece], font: Font) -> Text {
        var result = Text(verbatim: "")
        for piece in pieces {
            switch piece {
            case .text(let text):
                result = Text("\(result)\(Text(verbatim: text).font(font))")
            case .mention(let mention):
                if let image = image(for: mention) {
                    result = Text("\(result)\(Text(Image(nsImage: image)).baselineOffset(-5))")
                } else {
                    result = Text("\(result)\(Text(verbatim: mention.token).font(font))")
                }
            }
        }
        return result
    }
}
