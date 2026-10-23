// @author ixxxxoooo
// 原生编辑视图的「看不见的东西」:空白字符渲染(空格点、制表符箭头)与 Unicode 可疑字符高亮。

import AppKit
import DesignSystem
import EditorCore

/// 空白字符渲染模式(与 VS Code `editor.renderWhitespace` 一致)。
public enum WhitespaceRendering: String, Sendable, CaseIterable {
    /// 不显示。
    case none
    /// 显示行首、行尾与连续多个空白(单词之间的单个空格不显示)。
    case boundary
    /// 仅在选区内显示。
    case selection
    /// 全部显示。
    case all
}

extension OMEditorView {
    /// 从用户偏好读取的默认空白渲染模式。
    static var preferredWhitespaceRendering: WhitespaceRendering {
        WhitespaceRendering(rawValue: UserDefaults.standard.string(forKey: "editor.renderWhitespace") ?? "") ?? .selection
    }

    /// 绘制空白字符与 Unicode 高亮(只处理可见行)。
    func drawInvisibles(rows: [NativeDrawRow]) {
        let mode = whitespaceRendering
        guard mode != .none || highlightsUnicode else { return }
        let rope = model.document.snapshot
        let selectionRanges = model.selections.selections.filter { !$0.isEmpty }.map(\.range)
        if mode == .selection, selectionRanges.isEmpty, !highlightsUnicode { return }
        let faint = theme.gutterForeground.withAlphaComponent(0.55)
        let warning = NSColor(OMColors.warning)
        for item in rows {
            let span = TextSpan(lower: item.absoluteStart, upper: item.absoluteEnd)
            guard span.length > 0 else { continue }
            let units = rope.slice(span)
            if mode != .none { drawWhitespace(of: units, item: item, mode: mode, selections: selectionRanges, color: faint) }
            if highlightsUnicode {
                for finding in UnicodeHighlight.scan(units) { drawFinding(finding, item: item, color: warning) }
            }
        }
    }

    private func drawWhitespace(of units: ContiguousArray<UInt16>, item: NativeDrawRow, mode: WhitespaceRendering,
                                selections: [TextSpan], color: NSColor) {
        color.setFill()
        color.setStroke()
        let count = units.count
        // 行首/行尾空白区间(boundary 模式)。
        var leading = 0
        while leading < count, units[leading] == 0x20 || units[leading] == 0x09 { leading += 1 }
        var trailingStart = count
        while trailingStart > 0, units[trailingStart - 1] == 0x20 || units[trailingStart - 1] == 0x09 { trailingStart -= 1 }
        let midY = item.y + lineHeight / 2
        var index = 0
        while index < count {
            let unit = units[index]
            guard unit == 0x20 || unit == 0x09 else { index += 1; continue }
            defer { index += 1 }
            let absolute = item.absoluteStart + index
            switch mode {
            case .all: break
            case .selection:
                guard selections.contains(where: { absolute >= $0.location && absolute < $0.upperBound }) else { continue }
            case .boundary:
                let isEdge = index < leading || index >= trailingStart
                let neighbour = (index > 0 && (units[index - 1] == 0x20 || units[index - 1] == 0x09))
                    || (index + 1 < count && (units[index + 1] == 0x20 || units[index + 1] == 0x09))
                guard isEdge || neighbour else { continue }
            case .none: continue
            }
            let x1 = textOriginX + item.layout.x(forOffset: index + item.layout.start)
            let x2 = textOriginX + item.layout.x(forOffset: index + item.layout.start + 1)
            if unit == 0x20 {
                NSBezierPath(ovalIn: NSRect(x: (x1 + x2) / 2 - 1, y: midY - 1, width: 2, height: 2)).fill()
            } else if x2 - x1 > 6 {
                let path = NSBezierPath()
                path.lineWidth = 1
                path.move(to: NSPoint(x: x1 + 2, y: midY))
                path.line(to: NSPoint(x: x2 - 2, y: midY))
                path.move(to: NSPoint(x: x2 - 5, y: midY - 3))
                path.line(to: NSPoint(x: x2 - 2, y: midY))
                path.line(to: NSPoint(x: x2 - 5, y: midY + 3))
                path.stroke()
            }
        }
    }

    /// 在可疑字符处画警示框:零宽字符画成窄竖框,有宽度的字符框住字形。
    private func drawFinding(_ finding: UnicodeFinding, item: NativeDrawRow, color: NSColor) {
        let start = finding.offset + item.layout.start
        let x1 = textOriginX + item.layout.x(forOffset: start)
        let x2 = textOriginX + item.layout.x(forOffset: start + finding.length)
        var rect = NSRect(x: x1, y: item.y + 1, width: max(x2 - x1, 0), height: lineHeight - 2)
        if rect.width < 3 { rect = NSRect(x: x1 - 1.5, y: rect.minY, width: 4, height: rect.height) }
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
        color.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: OMRadius.tag, yRadius: OMRadius.tag)
        outline.lineWidth = 1
        outline.stroke()
    }
}
