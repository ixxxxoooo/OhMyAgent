// @author ixxxxoooo
// 编辑器命令路由:菜单、命令面板、大纲等应用层入口统一经这里,分发给当前活动的原生编辑器 `OMEditorView`。

import AppKit

/// 编辑器命令路由(仅主线程)。
@MainActor
public enum EditorRouter {
    /// 打开查找条。
    /// - Parameter replace: 是否展开替换行
    /// - Returns: 是否有编辑器响应
    @discardableResult
    public static func showFind(replace: Bool = false) -> Bool {
        guard let editor = OMEditorView.activeEditor() else { return false }
        editor.showFind(replace: replace)
        return true
    }

    /// 查找下一个/上一个(查找条未打开时先打开)。
    @discardableResult
    public static func findStep(forward: Bool) -> Bool {
        guard let editor = OMEditorView.activeEditor() else { return false }
        if editor.isFindVisible { editor.findStep(forward: forward) } else { editor.showFind() }
        return true
    }

    /// 跳到某行某列(均从 1 起)。
    public static func goToLine(_ line: Int, column: Int = 1) {
        OMEditorView.activeEditor()?.goToLine(line: line, column: column)
    }

    /// 执行一个编辑动作。
    public static func perform(_ action: EditorAction) {
        OMEditorView.activeEditor()?.perform(action)
    }

    /// 是否存在可响应的活动编辑器。
    public static var hasActiveEditor: Bool { OMEditorView.activeEditor() != nil }
}
