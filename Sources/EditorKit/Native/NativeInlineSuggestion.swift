// @author ixxxxoooo
// Tab 幽灵补全:停止输入一小会儿后向外部提供者请求「光标处续写」,以灰色幽灵文字内联显示,
// Tab 接受、Esc 或任何编辑/移动光标即丢弃。默认关闭(设置 → 编辑器 → 代码编辑)。

import AppKit
import EditorCore
import OMLog

/// 续写提供者:参数为光标前后的上下文;返回要在光标处插入的文本(nil/空表示没有建议)。
public typealias NativeInlineSuggestionProvider = @MainActor (_ prefix: String, _ suffix: String) async throws -> String?

/// 幽灵补全控制器(每个编辑器视图一个)。
@MainActor
public final class NativeInlineSuggestion {
    /// 提供者由外部注入;为 nil 或偏好关闭时不工作。
    public var provider: NativeInlineSuggestionProvider?
    /// 强制启用(测试用,忽略偏好);默认读取 `EditorBehaviorPrefs.ghostCompletion`。
    public var forceEnabled: Bool?
    /// 停顿多久后发起请求。
    public var delay: Duration = .milliseconds(450)

    private static let decorationID = 0x4200_0000
    private static let contextLimit = 2_000
    private weak var view: OMEditorView?
    private var task: Task<Void, Never>?
    private var anchor: Int?
    /// 当前显示的建议文本。
    public private(set) var suggestion: String?
    private var applying = false

    init(view: OMEditorView) { self.view = view }

    /// 是否启用。
    public var isEnabled: Bool { provider != nil && (forceEnabled ?? EditorBehaviorPrefs.ghostCompletion) && view?.model.isEditable == true }

    /// 是否正在显示建议。
    public var isShowing: Bool { suggestion != nil }

    // MARK: 事件

    /// 文档发生编辑:丢弃旧建议并重新排队请求。
    func documentDidChange() {
        guard !applying else { return }
        hide()
        schedule()
    }

    /// 选区变化:光标离开建议锚点则丢弃。
    func selectionDidChange() {
        guard let view, let anchor, suggestion != nil else { return }
        if view.model.selections.primary.head != anchor || !view.model.selections.primary.isEmpty { hide() }
    }

    /// 键盘钩子:Tab 接受、Esc 丢弃。
    func keyDown(_ event: NSEvent) -> Bool {
        guard suggestion != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, flags) {
        case (48, []): accept(); return true
        case (53, []): hide(); return true
        default: return false
        }
    }

    // MARK: 请求

    private func schedule() {
        task?.cancel()
        guard isEnabled, let view, view.composition == nil else { return }
        let version = view.model.document.version
        task = Task { [weak self] in
            try? await Task.sleep(for: self?.delay ?? .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.request(version: version)
        }
    }

    private func request(version: Int) async {
        guard let view, let provider, view.model.document.version == version, view.composition == nil else { return }
        let selections = view.model.selections
        guard !selections.isMulti, selections.primary.isEmpty else { return }
        let rope = view.model.document.snapshot
        let caret = selections.primary.head
        let line = rope.line(containing: caret)
        let lineStart = rope.lineStart(line)
        let lineEnd = lineStart + rope.lineLength(line)
        let before = rope.string(in: TextSpan(location: lineStart, length: caret - lineStart))
        let rest = rope.string(in: TextSpan(location: caret, length: lineEnd - caret))
        // 只在行尾(后面只有空白)且光标前有内容时请求,避免在代码中间打断
        guard !before.trimmingCharacters(in: .whitespaces).isEmpty, rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let prefixStart = max(caret - Self.contextLimit, 0)
        let prefix = rope.string(in: TextSpan(location: prefixStart, length: caret - prefixStart))
        let suffixEnd = min(caret + Self.contextLimit / 4, rope.length)
        let suffix = rope.string(in: TextSpan(location: caret, length: suffixEnd - caret))
        do {
            guard let text = try await provider(prefix, suffix), !text.isEmpty, !Task.isCancelled,
                  view.model.document.version == version, view.model.selections.primary.head == caret else { return }
            show(text, at: caret)
        } catch {
            if !Task.isCancelled { Log.editor.debug("幽灵补全请求失败", ["error": "\(error)"]) }
        }
    }

    // MARK: 展示与接受

    private func show(_ text: String, at caret: Int) {
        guard let view else { return }
        suggestion = text
        anchor = caret
        view.model.decorations.removeAll { $0.id == Self.decorationID }
        view.model.decorations.insert(Decoration(id: Self.decorationID, range: TextSpan(location: caret, length: 0), kind: .ghostText,
                                                 payload: text, removesWhenCollapsed: true))
        view.model.hasInlays = true
        view.cache.clear()
        view.needsDisplay = true
    }

    /// 丢弃当前建议与待发请求。
    public func hide() {
        task?.cancel()
        guard let view, suggestion != nil else { suggestion = nil; return }
        suggestion = nil
        anchor = nil
        view.model.decorations.removeAll { $0.id == Self.decorationID }
        if !view.model.decorations.items.contains(where: { $0.kind == .inlay }) { view.model.hasInlays = false }
        view.cache.clear()
        view.needsDisplay = true
    }

    /// 接受建议:在光标处插入全部文本。
    public func accept() {
        guard let view, let text = suggestion, let caret = anchor else { return }
        applying = true
        defer { applying = false }
        hide()
        do {
            try view.model.document.apply([DocumentEdit(range: TextSpan(location: caret, length: 0), text: text)],
                                          selectionsBefore: view.model.selections.selections,
                                          selectionsAfter: [Selection(caret: caret + (text as NSString).length)], coalesceKey: nil)
        } catch {
            Log.editor.error("接受幽灵补全失败", ["error": "\(error)"])
        }
    }

    /// 调试 / 测试:立即请求一次(忽略停顿与行尾条件以外的限制)。
    public func debugRequestNow() async {
        guard let view else { return }
        await request(version: view.model.document.version)
    }
}
