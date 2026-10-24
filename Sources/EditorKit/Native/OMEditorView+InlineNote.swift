// @author ixxxxoooo
// 行尾内联提示(如 Git blame):只显示在光标所在行的行尾(同 GitLens「当前行 blame」),不跟随鼠标。

import AppKit
import DesignSystem

extension OMEditorView {
    /// 在光标行(单光标、无选区、有焦点时)的行尾绘制提示文字。
    /// - Parameter rows: 本帧可见的视图行
    func drawInlineNote(rows: [NativeDrawRow]) {
        guard let inlineNote else { return }
        let selections = model.selections
        guard !selections.isMulti, selections.primary.isEmpty, window?.firstResponder === self else { return }
        let caretLine = model.document.snapshot.line(containing: selections.primary.head)
        let rope = model.document.snapshot
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(font.pointSize - 1, 9)), .foregroundColor: NSColor(OMColors.tertiaryText),
        ]
        for item in rows where item.line == caretLine && item.layout.end >= rope.lineLength(item.line) {
            guard let note = inlineNote(item.line), !note.isEmpty else { continue }
            let text = NSAttributedString(string: note, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: textOriginX + item.layout.width + 24, y: item.y + (lineHeight - size.height) / 2))
        }
    }
}
