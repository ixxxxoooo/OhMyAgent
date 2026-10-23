// @author ixxxxoooo
// 编辑器命令路由:菜单、命令面板、大纲等应用层入口统一经这里,按当前活动编辑器的引擎
// (原生 rope 引擎 `OMEditorView` 或 TextKit 引擎 `CodeEditorView`)分发,调用方不必关心引擎。

import AppKit

/// 编辑器命令路由(仅主线程)。
@MainActor
public enum EditorRouter {
    /// 打开查找条。
    /// - Parameter replace: 是否展开替换行
    /// - Returns: 是否有编辑器响应
    @discardableResult
    public static func showFind(replace: Bool = false) -> Bool {
        if let editor = OMEditorView.activeEditor() { editor.showFind(replace: replace); return true }
        return CodeEditorView.showFindInActiveEditor(replace: replace)
    }

    /// 查找下一个/上一个(查找条未打开时先打开)。
    @discardableResult
    public static func findStep(forward: Bool) -> Bool {
        if let editor = OMEditorView.activeEditor() {
            if editor.isFindVisible { editor.findStep(forward: forward) } else { editor.showFind() }
            return true
        }
        return CodeEditorView.findInActiveEditor(forward: forward)
    }

    /// 跳到某行某列(均从 1 起)。
    public static func goToLine(_ line: Int, column: Int = 1) {
        if let editor = OMEditorView.activeEditor() { editor.goToLine(line: line, column: column); return }
        CodeEditorView.activeEditor()?.goToLine(line, column: column)
    }

    /// 执行一个编辑动作。
    public static func perform(_ action: EditorAction) {
        if let editor = OMEditorView.activeEditor() { editor.perform(action); return }
        CodeEditorView.activeEditor()?.perform(action)
    }

    /// 是否存在可响应的活动编辑器。
    public static var hasActiveEditor: Bool { OMEditorView.activeEditor() != nil || CodeEditorView.activeEditor() != nil }
}
