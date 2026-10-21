// @author ixxxxoooo
// SwiftUI 封装:将 AppKit 编辑器嵌入 SwiftUI 视图层级。

import DesignSystem
import SwiftUI

/// SwiftUI 版代码编辑器。
public struct CodeEditor: NSViewRepresentable {
    public var text: String
    public var language: SyntaxLanguage
    public var isEditable: Bool
    public var revealLine: Int?
    public var markers: [Int: LineMarker]
    /// 用户编辑后回调(传出完整文本);仅可编辑时有意义。
    public var onChange: ((String) -> Void)?
    /// 语言服务器诊断
    public var diagnostics: [EditorDiagnostic]
    /// 悬停/跳转定义/补全回调
    public var features: EditorLanguageFeatures
    /// 「在对话中引用选区」回调(UTF-16 范围)
    public var onReferenceSelection: ((NSRange) -> Void)?
    /// Markdown 显示模式(仅 `.markdown` 语言有效)
    public var markdownMode: MarkdownEditorMode
    /// 光标/选区变化回调(状态栏的「行 列」用);nil 时不计算
    public var onCaretChange: ((EditorCaret) -> Void)?

    /// 创建编辑器。
    /// - Parameters:
    ///   - text: 文本内容
    ///   - language: 语言
    ///   - isEditable: 是否可编辑
    ///   - revealLine: 需要跳转的行(1 起始)
    ///   - markers: 行标记
    ///   - diagnostics: 诊断(下划线、行号栏圆点、悬停提示)
    ///   - features: 语言智能回调
    ///   - onReferenceSelection: 引用选区回调
    ///   - onChange: 编辑回调
    public init(text: String, language: SyntaxLanguage, isEditable: Bool = false, revealLine: Int? = nil, markers: [Int: LineMarker] = [:], diagnostics: [EditorDiagnostic] = [], features: EditorLanguageFeatures = EditorLanguageFeatures(), onReferenceSelection: ((NSRange) -> Void)? = nil, markdownMode: MarkdownEditorMode = .off, onCaretChange: ((EditorCaret) -> Void)? = nil, onChange: ((String) -> Void)? = nil) {
        self.onCaretChange = onCaretChange
        self.markdownMode = markdownMode
        self.onReferenceSelection = onReferenceSelection
        self.diagnostics = diagnostics
        self.features = features
        self.onChange = onChange
        self.text = text
        self.language = language
        self.isEditable = isEditable
        self.revealLine = revealLine
        self.markers = markers
    }

    /// 占满父级给出的空间,不把内部滚动视图的内容尺寸当作理想尺寸向上传递(否则会撑破标签页布局)。
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeEditorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> CodeEditorView {
        let view = CodeEditorView(isEditable: isEditable)
        context.coordinator.loadedText = text
        context.coordinator.loadedLanguage = language
        wire(view, context.coordinator)
        view.markdownMode = markdownMode
        view.setText(text, language: language)
        view.features = features
        view.onReferenceSelection = onReferenceSelection
        view.onCaretChange = onCaretChange
        view.setDiagnostics(diagnostics)
        return view
    }

    /// 把编辑回调接到编辑器:先记录已装载文本,避免随后的 `updateNSView` 把用户输入当作外部变更而整体重置(光标跳动)。
    private func wire(_ view: CodeEditorView, _ coordinator: Coordinator) {
        view.onTextChange = { [weak coordinator] text in
            coordinator?.loadedText = text
            coordinator?.onChange?(text)
        }
    }

    public func updateNSView(_ view: CodeEditorView, context: Context) {
        view.syncTabActive(context.environment.tabIsActive)
        view.markdownMode = markdownMode
        context.coordinator.onChange = onChange
        wire(view, context.coordinator)
        if context.coordinator.loadedText != text || context.coordinator.loadedLanguage != language {
            context.coordinator.loadedText = text
            context.coordinator.loadedLanguage = language
            view.setText(text, language: language)
        }
        view.textView.isEditable = isEditable
        view.features = features
        view.onReferenceSelection = onReferenceSelection
        view.onCaretChange = onCaretChange
        view.setDiagnostics(diagnostics)
        view.lineMarkers = markers
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            // 等待索引就绪后再跳转
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                view.reveal(line: line)
            }
        }
    }

    /// 记录已装载状态,避免重复装载大文本。
    @MainActor
    public final class Coordinator {
        var loadedText: String?
        var loadedLanguage: SyntaxLanguage?
        var revealedLine: Int?
        var onChange: ((String) -> Void)?
    }
}

/// 编辑器光标状态(行、列均 1 起始;`selectedLength` 为选中的字符数)。
public struct EditorCaret: Equatable, Sendable {
    public var line: Int
    public var column: Int
    public var selectedLength: Int

    /// - Parameters:
    ///   - line: 行号
    ///   - column: 列号
    ///   - selectedLength: 选中字符数
    public init(line: Int, column: Int, selectedLength: Int) {
        self.line = line
        self.column = column
        self.selectedLength = selectedLength
    }
}
