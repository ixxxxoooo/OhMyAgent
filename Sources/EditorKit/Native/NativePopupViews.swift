// @author ixxxxoooo
// 原生编辑器的自绘浮层:列表浮层(补全、代码操作、Peek 引用)、信息卡片(悬停、签名)、灯泡按钮。
// 颜色全部取 `OMColors` 令牌,随主题刷新;圆角取 `OMRadius`。

import AppKit
import DesignSystem
import SwiftUI

/// 列表浮层的一行。
struct NativePopupRow: Equatable {
    var title: String
    var detail: String?
    var badge: String?
    /// `title` 里需要高亮的 Character 下标。
    var highlights: [Int] = []
}

/// 自绘列表浮层:最多显示 `maxVisible` 行,↑↓ 由宿主驱动选中,点击/双击接受。
@MainActor
final class NativePopupListView: NSView {
    static let rowHeight: CGFloat = 22
    var rows: [NativePopupRow] = [] { didSet { clampSelection(); needsDisplay = true } }
    var selected = 0 { didSet { revealSelected(); needsDisplay = true } }
    /// 选中项的说明文字(显示在列表底部,可为空)。
    var footer: String? { didSet { needsDisplay = true } }
    var maxVisible = 9
    private var topRow = 0
    var onAccept: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    static var uiFont: NSFont { NSFont.systemFont(ofSize: 11.5 * OMScale.ui, weight: .regular) }
    private static var badgeFont: NSFont { NSFont.systemFont(ofSize: 10 * OMScale.ui, weight: .medium) }

    /// 列表内容所需的尺寸。
    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let font = Self.uiFont
        var width: CGFloat = 220
        for row in rows.prefix(80) {
            let title = (row.title as NSString).size(withAttributes: [.font: font]).width
            let detail = row.detail.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 16 } ?? 0
            width = max(width, 34 + title + detail + 12)
        }
        let visible = min(rows.count, maxVisible)
        var height = CGFloat(visible) * Self.rowHeight + 8
        if footer != nil { height += 40 }
        return CGSize(width: min(width, maxWidth), height: height)
    }

    private func clampSelection() {
        selected = rows.isEmpty ? 0 : min(max(selected, 0), rows.count - 1)
        topRow = min(topRow, max(rows.count - maxVisible, 0))
    }

    private func revealSelected() {
        if selected < topRow { topRow = selected }
        if selected >= topRow + maxVisible { topRow = selected - maxVisible + 1 }
    }

    /// 选中项上移/下移(循环)。
    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
    }

    /// 翻页。
    func movePage(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + delta * maxVisible, 0), rows.count - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = OMRadius.card
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(OMColors.card).setFill()
        background.fill()
        NSColor(OMColors.hairline).setStroke()
        background.lineWidth = 0.5
        background.stroke()
        guard !rows.isEmpty else { return }
        let font = Self.uiFont
        let textColor = NSColor(OMColors.primaryText)
        let dim = NSColor(OMColors.secondaryText)
        let accent = NSColor(OMColors.accent)
        let visible = min(rows.count - topRow, maxVisible)
        for slot in 0..<max(visible, 0) {
            let index = topRow + slot
            let row = rows[index]
            let rect = NSRect(x: 4, y: 4 + CGFloat(slot) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
            if index == selected {
                NSColor(OMColors.selectedFill).setFill()
                NSBezierPath(roundedRect: rect, xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
            }
            var textX = rect.minX + 8
            if let badge = row.badge {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: accent]
                let size = (badge as NSString).size(withAttributes: attrs)
                (badge as NSString).draw(at: NSPoint(x: textX + (14 - size.width) / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
                textX += 20
            }
            let title = NSMutableAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: textColor])
            if !row.highlights.isEmpty {
                let characters = Array(row.title)
                var utf16Offsets: [Int] = []
                var running = 0
                for ch in characters { utf16Offsets.append(running); running += String(ch).utf16.count }
                for hit in row.highlights where hit < characters.count {
                    title.addAttributes([.foregroundColor: accent, .font: NSFont.systemFont(ofSize: font.pointSize, weight: .medium)],
                                        range: NSRange(location: utf16Offsets[hit], length: String(characters[hit]).utf16.count))
                }
            }
            var detailWidth: CGFloat = 0
            if let detail = row.detail, !detail.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dim]
                detailWidth = min((detail as NSString).size(withAttributes: attrs).width, rect.width * 0.4)
                let detailRect = NSRect(x: rect.maxX - detailWidth - 8, y: rect.midY - 7, width: detailWidth, height: 14)
                (detail as NSString).draw(with: detailRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs)
            }
            let titleRect = NSRect(x: textX, y: rect.midY - 7.5, width: max(rect.maxX - textX - detailWidth - 16, 20), height: 15)
            title.draw(with: titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
        if let footer, !footer.isEmpty {
            let y = 4 + CGFloat(min(rows.count, maxVisible)) * Self.rowHeight + 2
            NSColor(OMColors.hairline).setFill()
            NSRect(x: 8, y: y, width: bounds.width - 16, height: 0.5).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dim]
            (footer as NSString).draw(with: NSRect(x: 10, y: y + 5, width: bounds.width - 20, height: 30),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    private func index(at point: NSPoint) -> Int? {
        let slot = Int((point.y - 4) / Self.rowHeight)
        guard point.y >= 4, slot >= 0, slot < min(rows.count - topRow, maxVisible) else { return nil }
        return topRow + slot
    }

    override func mouseMoved(with event: NSEvent) {
        if let hit = index(at: convert(event.locationInWindow, from: nil)), hit != selected { selected = hit; onHover?(hit) }
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = index(at: convert(event.locationInWindow, from: nil)) {
            selected = hit
            if event.clickCount >= 2 || event.modifierFlags.contains(.command) { onAccept?(hit) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let hit = index(at: convert(event.locationInWindow, from: nil)), hit == selected, event.clickCount == 1 { onAccept?(hit) }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 0 ? -1 : 1
        if abs(event.scrollingDeltaY) < 0.5 { return }
        topRow = min(max(topRow + step, 0), max(rows.count - maxVisible, 0))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}

/// 信息卡片:显示富文本(悬停说明、签名帮助)。
@MainActor
final class NativeInfoCardView: NSView {
    private(set) var text = NSAttributedString()
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 300
    static let padding: CGFloat = 10

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// 设置内容并返回所需尺寸。
    @discardableResult
    func setContent(_ content: NSAttributedString) -> CGSize {
        text = content
        needsDisplay = true
        let limit = Self.maxWidth - Self.padding * 2
        let bounds = content.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: min(ceil(bounds.width) + Self.padding * 2 + 2, Self.maxWidth),
                      height: min(ceil(bounds.height) + Self.padding * 2, Self.maxHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: OMRadius.card, yRadius: OMRadius.card)
        NSColor(OMColors.card).setFill()
        background.fill()
        NSColor(OMColors.hairline).setStroke()
        background.lineWidth = 0.5
        background.stroke()
        text.draw(with: bounds.insetBy(dx: Self.padding, dy: Self.padding), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// 精简 Markdown 渲染:代码围栏、行内代码、标题、段落。
    static func render(markdown: String, monoFont: NSFont) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 12 * OMScale.ui)
        let mono = NSFont.monospacedSystemFont(ofSize: max(monoFont.pointSize - 1, 10), weight: .regular)
        let color = NSColor(OMColors.primaryText)
        let dim = NSColor(OMColors.secondaryText)
        let result = NSMutableAttributedString()
        var inFence = false
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var pendingBlank = false
        for raw in lines {
            if raw.hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                result.append(NSAttributedString(string: raw + "\n", attributes: [.font: mono, .foregroundColor: color]))
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { pendingBlank = result.length > 0; continue }
            if pendingBlank { result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])); pendingBlank = false }
            var line = raw
            var weight = NSFont.Weight.regular
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" || $0 == " " }))
                weight = .medium
            }
            result.append(inline(line, base: NSFont.systemFont(ofSize: base.pointSize, weight: weight), mono: mono, color: weight == .medium ? color : dim.blended(withFraction: 0.35, of: color) ?? dim))
            result.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        }
        while result.length > 0, result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    /// 行内:`code` 用等宽字体,`**粗**` 去掉标记,链接只留文字。
    private static func inline(_ line: String, base: NSFont, mono: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var code = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: [.font: code ? mono : base, .foregroundColor: code ? NSColor(OMColors.primaryText) : color]))
            buffer = ""
        }
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "`" { flush(); code.toggle() } else if char == "*", line[index...].hasPrefix("**") {
                index = line.index(after: index)
            } else if char == "[", !code, let close = line[index...].firstIndex(of: "]"),
                      line.index(after: close) < line.endIndex, line[line.index(after: close)] == "(", let end = line[close...].firstIndex(of: ")") {
                buffer += line[line.index(after: index)..<close]
                index = end
            } else {
                buffer.append(char)
            }
            index = line.index(after: index)
        }
        flush()
        return result
    }

    /// 签名帮助的富文本:当前参数加粗并用强调色。
    static func render(signature: String, activeParameter: NSRange?, monoFont: NSFont) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: max(monoFont.pointSize - 1, 10), weight: .regular)
        let result = NSMutableAttributedString(string: signature, attributes: [.font: mono, .foregroundColor: NSColor(OMColors.secondaryText)])
        if let range = activeParameter, range.location >= 0, NSMaxRange(range) <= result.length {
            result.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: mono.pointSize, weight: .medium),
                                  .foregroundColor: NSColor(OMColors.accent)], range: range)
        }
        return result
    }
}

/// 行号栏里的灯泡按钮(有可用代码操作时显示)。
@MainActor
final class NativeLightbulbView: NSView {
    var onClick: (() -> Void)?
    var isQuickFix = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(isQuickFix ? OMColors.warning : OMColors.accent)
        color.setStroke()
        let bulb = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 4.5, y: bounds.midY - 6.5, width: 9, height: 9))
        bulb.lineWidth = 1.2
        bulb.stroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: bounds.midX - 2.5, y: bounds.midY + 4))
        base.line(to: NSPoint(x: bounds.midX + 2.5, y: bounds.midY + 4))
        base.move(to: NSPoint(x: bounds.midX - 1.5, y: bounds.midY + 6.2))
        base.line(to: NSPoint(x: bounds.midX + 1.5, y: bounds.midY + 6.2))
        base.lineWidth = 1.2
        base.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
}
