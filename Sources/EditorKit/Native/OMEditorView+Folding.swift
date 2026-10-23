// @author ixxxxoooo
// 原生编辑视图的折叠界面:行号栏折叠箭头(悬停显示/已折叠常驻)、折叠占位「…」、点击展开、快捷键。

import AppKit
import DesignSystem
import EditorCore

extension OMEditorView {
    /// 折叠占位的尺寸。
    private static let placeholderWidth: CGFloat = 24

    // MARK: 行号栏箭头

    /// 绘制行号栏里的折叠箭头;只画区域起始行,未折叠的箭头仅在鼠标悬停行号栏时显示。
    func drawFoldMarkers(rows: [NativeDrawRow]) {
        guard chrome.contains(.folding), !model.folds.regions.isEmpty else { return }
        let color = theme.gutterForeground
        color.setStroke()
        for item in rows where item.rowInLine == 0 {
            guard model.folds.region(startingAt: item.line) != nil else { continue }
            let collapsed = model.folds.isCollapsed(startLine: item.line)
            guard collapsed || gutterHovered else { continue }
            let centerX = gutterWidth - foldColumnWidth / 2 - 1
            let centerY = item.y + lineHeight / 2
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if collapsed {
                path.move(to: NSPoint(x: centerX - 1.5, y: centerY - 3.5))
                path.line(to: NSPoint(x: centerX + 2, y: centerY))
                path.line(to: NSPoint(x: centerX - 1.5, y: centerY + 3.5))
            } else {
                path.move(to: NSPoint(x: centerX - 3.5, y: centerY - 1.5))
                path.line(to: NSPoint(x: centerX, y: centerY + 2))
                path.line(to: NSPoint(x: centerX + 3.5, y: centerY - 1.5))
            }
            path.stroke()
        }
    }

    /// 行号栏点击是否命中折叠箭头列;命中则切换折叠并返回 true。
    func foldGutterClick(at point: CGPoint) -> Bool {
        guard chrome.contains(.folding), point.x >= gutterWidth - foldColumnWidth - 2, point.x < gutterWidth else { return false }
        let offset = offset(at: CGPoint(x: gutterWidth + 1, y: point.y))
        let line = model.document.snapshot.line(containing: offset)
        guard model.folds.region(startingAt: line) != nil else { return false }
        model.toggleFold(line: line)
        return true
    }

    // MARK: 折叠占位

    /// 已折叠行行尾的占位矩形(行尾 + 4pt)。
    private func placeholderRect(for item: NativeDrawRow) -> CGRect {
        CGRect(x: textOriginX + item.layout.width + 6, y: item.y + 3, width: Self.placeholderWidth, height: max(lineHeight - 6, 8))
    }

    /// 绘制折叠占位。
    func drawFoldPlaceholders(rows: [NativeDrawRow]) {
        guard !model.folds.collapsedStarts.isEmpty else { return }
        let rope = model.document.snapshot
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: theme.gutterForeground]
        for item in rows where model.folds.isCollapsed(startLine: item.line) {
            // 只画在逻辑行的最后一个视图行上。
            guard item.layout.end >= rope.lineLength(item.line) else { continue }
            let rect = placeholderRect(for: item)
            NSColor(OMColors.subtleFill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
            let label = "…" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    /// 点击折叠占位展开;命中返回 true。
    func foldPlaceholderClick(at point: CGPoint) -> Bool {
        guard !model.folds.collapsedStarts.isEmpty, point.x >= gutterWidth else { return false }
        let rows = visibleDrawRows()
        let rope = model.document.snapshot
        for item in rows where model.folds.isCollapsed(startLine: item.line) && item.layout.end >= rope.lineLength(item.line) {
            if placeholderRect(for: item).insetBy(dx: -2, dy: -2).contains(point) {
                model.unfold(line: item.line)
                return true
            }
        }
        return false
    }

    // MARK: 悬停

    /// 鼠标移动:行号栏悬停状态变化时重绘行号栏。
    func updateGutterHover(at point: CGPoint?) {
        let hovered = point.map { $0.x < gutterWidth && $0.x >= 0 && $0.y >= 0 } ?? false
        guard hovered != gutterHovered else { return }
        gutterHovered = hovered
        setNeedsDisplay(NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height))
    }

    // MARK: 命令

    /// 折叠光标所在区域(⌥⌘[)。
    public func foldAtCaret() {
        model.fold(line: model.document.snapshot.line(containing: model.selections.primary.head))
        revealPrimaryCaret()
    }

    /// 展开光标所在折叠(⌥⌘])。
    public func unfoldAtCaret() {
        model.unfold(line: model.document.snapshot.line(containing: model.selections.primary.head))
    }
}

// MARK: 应用层动作

extension OMEditorView {
    /// 跳转到某行某列(均从 1 起),光标放到该位置并居中显示。
    public func goToLine(line: Int, column: Int) {
        let rope = model.document.snapshot
        let target = min(max(line - 1, 0), max(rope.lineCount - 1, 0))
        let offset = rope.offset(of: TextPosition(line: target, column: max(column - 1, 0)))
        model.setSelections(SelectionSet(caret: offset))
        scrollToLine(target, centered: true)
        revealPrimaryCaret()
    }

    /// 执行编辑动作(命令面板与快捷键共用)。
    public func perform(_ action: EditorAction) {
        switch action {
        case .toggleComment: model.toggleLineComment()
        case .deleteLine: model.deleteLines()
        case .moveLineUp: model.moveLines(up: true)
        case .moveLineDown: model.moveLines(up: false)
        case .duplicateLineUp: model.duplicateLines(down: false)
        case .duplicateLineDown: model.duplicateLines(down: true)
        case .addNextOccurrence: _ = model.selectNextOccurrence()
        case .fold: foldAtCaret()
        case .unfold: unfoldAtCaret()
        case .foldAll: model.foldAll()
        case .unfoldAll: model.unfoldAll()
        }
        revealPrimaryCaret()
    }
}
