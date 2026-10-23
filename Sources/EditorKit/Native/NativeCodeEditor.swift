// @author ixxxxoooo
// SwiftUI 封装:把原生 `OMEditorView`(native2 引擎)嵌入 SwiftUI。
// 与旧 `CodeEditor` 的区别:文本不再以 String 往返,而是共享一个 `EditorDocument`(rope),因此输入不会整篇拷贝。

import AppKit
import DesignSystem
import EditorCore
import SwiftUI

/// SwiftUI 版原生代码编辑器。
public struct NativeCodeEditor: NSViewRepresentable {
    public var document: EditorDocument
    public var language: SyntaxLanguage
    public var isEditable: Bool
    public var revealLine: Int?
    public var markers: [Int: LineMarker]
    public var diagnostics: [EditorDiagnostic]
    public var wrapsLines: Bool
    /// 文件路径(snippet 变量 `TM_FILENAME` 等使用)。
    public var filePath: String?
    /// IDE 外围视图(缩略图、粘性滚动、折叠、概览尺)。
    public var chrome: EditorChrome
    /// 光标/选区变化回调(状态栏「行 列」)。
    public var onCaretChange: ((EditorCaret) -> Void)?
    /// 文档变化(用户编辑或外部写入)回调,宿主据此防抖同步字符串镜像与脏标记。
    public var onEdited: ((DocumentChange) -> Void)?

    /// 创建编辑器。
    /// - Parameters:
    ///   - document: 共享文档
    ///   - language: 语言
    ///   - isEditable: 是否可编辑
    ///   - revealLine: 需要跳转的行(1 起始)
    ///   - markers: 行号栏标记(0 起始行号)
    ///   - diagnostics: 语言服务器诊断
    ///   - wrapsLines: 是否软换行
    ///   - chrome: 外围视图
    ///   - filePath: 文件路径
    ///   - onCaretChange: 光标变化回调
    ///   - onEdited: 文档变化回调
    public init(document: EditorDocument, language: SyntaxLanguage, isEditable: Bool = true, revealLine: Int? = nil,
                markers: [Int: LineMarker] = [:], diagnostics: [EditorDiagnostic] = [], wrapsLines: Bool = false, chrome: EditorChrome = [], filePath: String? = nil,
                onCaretChange: ((EditorCaret) -> Void)? = nil, onEdited: ((DocumentChange) -> Void)? = nil) {
        self.document = document
        self.language = language
        self.isEditable = isEditable
        self.revealLine = revealLine
        self.markers = markers
        self.diagnostics = diagnostics
        self.wrapsLines = wrapsLines
        self.chrome = chrome
        self.filePath = filePath
        self.onCaretChange = onCaretChange
        self.onEdited = onEdited
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: OMEditorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> OMEditorView {
        let model = NativeEditorModel(document: document, language: language)
        model.isEditable = isEditable
        model.fileName = filePath
        let view = OMEditorView(model: model, theme: EditorTheme.default, font: EditorFontPrefs.preferredFont)
        view.wrapsLines = wrapsLines
        view.chrome = chrome
        context.coordinator.language = language
        sync(view, context.coordinator)
        return view
    }

    public func updateNSView(_ view: OMEditorView, context: Context) {
        view.model.isEditable = isEditable
        if context.coordinator.language != language {
            context.coordinator.language = language
            view.model.language = language
            view.model.indentUnit = NativeEditorModel.detectIndentUnit(document.snapshot, language: language)
            view.reloadSyntax()
        }
        if view.wrapsLines != wrapsLines { view.wrapsLines = wrapsLines }
        if view.chrome != chrome { view.chrome = chrome }
        sync(view, context.coordinator)
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            let target = min(max(line - 1, 0), max(document.lineCount - 1, 0))
            view.model.setSelections(SelectionSet(caret: document.snapshot.lineStart(target)))
            view.scrollToLine(target)
        }
    }

    public static func dismantleNSView(_ view: OMEditorView, coordinator: Coordinator) {
        view.model.detach()
    }

    /// 同步回调、标记与诊断。
    private func sync(_ view: OMEditorView, _ coordinator: Coordinator) {
        view.onTextChange = onEdited
        view.lineMarkers = markers
        if coordinator.diagnostics != diagnostics {
            coordinator.diagnostics = diagnostics
            view.setDiagnostics(diagnostics)
        }
        if let onCaretChange {
            let model = view.model
            view.onSelectionChange = { [weak model] in
                guard let model else { return }
                let rope = model.document.snapshot
                let primary = model.selections.primary
                let position = rope.position(at: primary.head)
                onCaretChange(EditorCaret(line: position.line + 1, column: position.column + 1, selectedLength: primary.range.length))
            }
        } else {
            view.onSelectionChange = nil
        }
    }

    /// 记录已应用状态,避免重复处理。
    @MainActor
    public final class Coordinator {
        var language: SyntaxLanguage?
        var revealedLine: Int?
        var diagnostics: [EditorDiagnostic] = []
    }
}

extension OMEditorView {
    /// 设置诊断:写入装饰(波浪线)与行号栏圆点。
    /// - Parameter items: 诊断列表
    public func setDiagnostics(_ items: [EditorDiagnostic]) {
        let rope = model.document.snapshot
        var list: [Decoration] = []
        var lines: [Int: EditorDiagnostic.Severity] = [:]
        list.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let lower = min(max(item.range.location, 0), rope.length)
            let upper = min(max(item.range.location + max(item.range.length, 1), lower), rope.length)
            let kind: DecorationKind
            switch item.severity {
            case .error: kind = .diagnosticError
            case .warning: kind = .diagnosticWarning
            case .information: kind = .diagnosticInfo
            case .hint: kind = .diagnosticHint
            }
            list.append(Decoration(id: 1_000_000 + index, range: TextSpan(lower: lower, upper: upper), kind: kind, payload: item.message, removesWhenCollapsed: false))
            let line = rope.line(containing: lower)
            if let existing = lines[line], existing.rawValue <= item.severity.rawValue {} else { lines[line] = item.severity }
        }
        model.decorations.removeAll { decoration in
            switch decoration.kind {
            case .diagnosticError, .diagnosticWarning, .diagnosticInfo, .diagnosticHint: true
            default: false
            }
        }
        for decoration in list { model.decorations.insert(decoration) }
        diagnosticLines = lines
        needsDisplay = true
    }
}
