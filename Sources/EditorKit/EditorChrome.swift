// @author ixxxxoooo
// 编辑器的 IDE 外围视图:右侧缩略图(minimap)与顶部粘性滚动(sticky scroll)。
// 两者都只读取编辑器的行索引、文本与滚动位置,不改动文本布局。

import AppKit
import DesignSystem

/// 要显示哪些 IDE 外围视图。
public struct EditorChrome: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 右侧缩略图
    public static let minimap = EditorChrome(rawValue: 1 << 0)
    /// 顶部粘性滚动
    public static let stickyScroll = EditorChrome(rawValue: 1 << 1)
    /// 行号栏折叠箭头与代码折叠
    public static let folding = EditorChrome(rawValue: 1 << 2)
    /// 右侧概览尺(诊断、查找命中、Git 改动的缩略标记)
    public static let overviewRuler = EditorChrome(rawValue: 1 << 3)
}

/// 偏好键(设置 → 编辑器 → 代码编辑)。
public extension EditorBehaviorPrefs {
    /// 缩略图开关的键
    static let minimapKey = "editor.minimap"
    /// 粘性滚动开关的键
    static let stickyScrollKey = "editor.stickyScroll"
    /// 幽灵补全(Tab 接受 AI 续写)开关的键
    static let ghostCompletionKey = "editor.ghostCompletion"
    /// 是否启用幽灵补全(默认关:每次停顿都会向模型发请求)。
    static var ghostCompletion: Bool { UserDefaults.standard.object(forKey: ghostCompletionKey) as? Bool ?? false }
    /// 是否显示缩略图(默认开)。
    static var minimap: Bool { UserDefaults.standard.object(forKey: minimapKey) as? Bool ?? true }
    /// 是否显示粘性滚动(默认开)。
    static var stickyScroll: Bool { UserDefaults.standard.object(forKey: stickyScrollKey) as? Bool ?? true }
}

/// 粘性滚动条:顶部叠放当前视口第一行所在的外层块头行(最多 3 行),点击跳到该行。
@MainActor
final class EditorStickyView: NSView {
    unowned let editor: CodeEditorView
    /// 当前显示的块头行号(0 起始)
    private(set) var lines: [Int] = []

    init(editor: CodeEditorView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// 每行高度(与编辑器行高一致)。
    private var rowHeight: CGFloat { max(editor.theme.paragraphStyle.minimumLineHeight, 16) }

    /// 按当前滚动位置重算要显示的块头;结果变化才重绘。
    func refresh() {
        guard editor.lineIndexIsLive, editor.lineIndex.lineCount > 1 else { clear(); return }
        let textView = editor.textView
        let visible = editor.scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        let offset = textView.characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: visible.minY + origin.y + 1))
        let topLine = editor.lineIndex.line(containing: min(offset, editor.lineIndex.length))
        let ns = textView.string as NSString
        let index = editor.lineIndex
        let found = EditorScopes.enclosing(topLine: topLine, lineCount: index.lineCount) { line in
            guard let range = index.range(ofLine: line), range.length < 400 else { return nil }
            return ns.substring(with: range)
        }
        guard found != lines else { return }
        lines = found
        isHidden = found.isEmpty
        needsDisplay = true
        invalidateIntrinsicContentSize()
        editor.stickyHeightDidChange(CGFloat(found.count) * rowHeight)
    }

    private func clear() {
        guard !lines.isEmpty else { return }
        lines = []
        isHidden = true
        editor.stickyHeightDidChange(0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = editor.theme
        theme.background.setFill()
        bounds.fill(using: .sourceOver)
        guard let storage = editor.textView.textStorage else { return }
        let index = editor.lineIndex
        // 文本左边界:取文本视图里第一个字符的横坐标换算到本视图,保证与正文对齐
        let textView = editor.textView
        let padding = textView.textContainer?.lineFragmentPadding ?? 0
        let textX = textView.convert(NSPoint(x: textView.textContainerOrigin.x + padding, y: 0), to: self).x
        for (row, line) in lines.enumerated() {
            guard let range = index.range(ofLine: line) else { continue }
            var trimmed = range
            if trimmed.length > 0, (storage.string as NSString).character(at: NSMaxRange(range) - 1) == 10 { trimmed.length -= 1 }
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: trimmed))
            text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
            let y = CGFloat(row) * rowHeight
            text.draw(at: NSPoint(x: textX, y: y + (rowHeight - theme.font.pointSize * 1.25) / 2))
        }
        theme.foreground.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        let row = Int(convert(event.locationInWindow, from: nil).y / rowHeight)
        guard lines.indices.contains(row) else { return }
        editor.goToLine(lines[row] + 1)
    }
}
