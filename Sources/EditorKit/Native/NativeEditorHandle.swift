// @author ixxxxoooo
// 原生编辑器的外部操作句柄:宿主(SwiftUI)用它为编辑器附加自绘右键菜单,而不必持有 `OMEditorView`。
// 句柄只弱引用视图;视图销毁后所有查询返回「不可用」,所有操作为空操作。

import AppKit
import EditorCore

/// 编辑器操作句柄。由宿主创建并传给 `NativeCodeEditor`,视图装入时自动绑定。
@MainActor
public final class NativeEditorHandle {
    weak var view: OMEditorView?

    public init() {}

    /// 是否已绑定到存活的视图。
    public var isAttached: Bool { view != nil }
    /// 是否可编辑。
    public var isEditable: Bool { view?.model.isEditable ?? false }
    /// 是否存在非空选区。
    public var hasSelection: Bool { view?.model.selections.selections.contains { !$0.isEmpty } ?? false }
    /// 剪贴板是否有文本可粘贴。
    public var canPaste: Bool { isEditable && NSPasteboard.general.string(forType: .string)?.isEmpty == false }
    /// 是否可撤销 / 重做。
    public var canUndo: Bool { isEditable && (view?.model.document.canUndo ?? false) }
    public var canRedo: Bool { isEditable && (view?.model.document.canRedo ?? false) }
    /// 语言服务是否提供跳转定义 / 引用 / 格式化 / 代码操作。
    public var supportsDefinition: Bool { view?.languageController.services.definition != nil }
    public var supportsReferences: Bool { view?.languageController.services.references != nil }
    public var supportsFormat: Bool { isEditable && view?.languageController.services.format != nil }
    public var supportsCodeActions: Bool { view?.languageController.services.codeActions != nil }
    /// 是否可发起 ⌘K 行内编辑 / ⌘L 引用选区。
    public var supportsInlineEdit: Bool { view?.inlineEdit.isAvailable ?? false }
    public var supportsReference: Bool { view?.onReferenceSelection != nil }

    /// 在右键位置准备上下文:点击点不在已有选区内时,把光标移到点击处(与 VS Code / Cursor 一致)。
    /// 宿主应在构建菜单内容的闭包开头调用;事件取自当前正在派发的右键事件。
    public func prepareContextMenu() {
        guard let view, let event = NSApp.currentEvent, event.window === view.window else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point) else { return }
        let offset = view.offset(at: point)
        let inside = view.model.selections.selections.contains { !$0.isEmpty && $0.range.location <= offset && offset <= $0.range.upperBound }
        if !inside { view.model.setSelections(SelectionSet(caret: offset)) }
        view.window?.makeFirstResponder(view)
    }

    // MARK: 操作

    public func cut() { view?.cut(nil) }
    public func copy() { view?.copy(nil) }
    public func paste() { view?.paste(nil) }
    public func selectAll() { view?.selectAll(nil) }
    public func undo() { view?.performUndo() }
    public func redo() { view?.performRedo() }
    public func find() { view?.showFind() }
    public func goToDefinition() { view?.languageController.goToDefinition() }
    public func findReferences() { view?.languageController.findReferences() }
    public func formatDocument() { view?.languageController.formatDocument() }
    public func showCodeActions() { view?.languageController.showCodeActions() }
    public func beginInlineEdit() { view?.inlineEdit.begin() }

    /// 把当前选区交给宿主的「引用到对话」回调。
    public func referenceSelection() {
        guard let view, let handler = view.onReferenceSelection else { return }
        let range = view.model.selections.primary.range
        handler(NSRange(location: range.location, length: range.length))
    }
}
