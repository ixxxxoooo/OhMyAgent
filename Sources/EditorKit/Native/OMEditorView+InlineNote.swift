// @author ixxxxoooo
// 行尾内联提示(如 Git blame):显示在光标所在行与鼠标悬停行的行尾,与旧 TextKit 引擎行为一致。

import AppKit
import DesignSystem

extension OMEditorView {
    /// 更新鼠标悬停的提示行(无提示提供者时不处理)。
    /// - Parameter point: 鼠标位置(视图坐标);nil 表示鼠标已离开
    func updateHoverNoteLine(at point: CGPoint?) {
        guard inlineNote != nil else { return }
        guard let point, point.x >= gutterWidth, model.lineMap.totalRows > 0 else {
            if hoverNoteLine != nil { hoverNoteLine = nil }
            return
        }
        let line = cache.rowLayout(forRow: row(atY: point.y))?.line
        if line != hoverNoteLine { hoverNoteLine = line }
    }

    /// 在光标行(单光标、无选区、有焦点时)与悬停行的行尾绘制提示文字。
    /// - Parameter rows: 本帧可见的视图行
    func drawInlineNote(rows: [NativeDrawRow]) {
        guard let inlineNote else { return }
        var wanted = Set<Int>()
        let selections = model.selections
        if !selections.isMulti, selections.primary.isEmpty, window?.firstResponder === self {
            wanted.insert(model.document.snapshot.line(containing: selections.primary.head))
        }
        if let hoverNoteLine { wanted.insert(hoverNoteLine) }
        guard !wanted.isEmpty else { return }
        let rope = model.document.snapshot
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(font.pointSize - 1, 9)), .foregroundColor: NSColor(OMColors.tertiaryText),
        ]
        for item in rows where wanted.contains(item.line) && item.layout.end >= rope.lineLength(item.line) {
            guard let note = inlineNote(item.line), !note.isEmpty else { continue }
            let text = NSAttributedString(string: note, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: textOriginX + item.layout.width + 24, y: item.y + (lineHeight - size.height) / 2))
        }
    }
}
