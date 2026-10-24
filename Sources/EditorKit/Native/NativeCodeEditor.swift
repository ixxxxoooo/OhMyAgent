// @author ixxxxoooo
// SwiftUI 封装:把原生 `OMEditorView`(native2 引擎)嵌入 SwiftUI。
// 与旧 `CodeEditor` 的区别:文本不再以 String 往返,而是共享一个 `EditorDocument`(rope),因此输入不会整篇拷贝。

import AppKit
import DesignSystem
import DiffKit
import EditorCore
import SwiftUI

/// 待审阅的 Agent 改动(行内 Diff)。
public struct NativeAgentReview {
    /// 变化键:相同则不重新布局(调用方用「路径 + 内容哈希 + 待审阅块」拼接)。
    public var key: String
    /// 旧(Agent 写入前)→ 新(当前文件内容)的差异。
    public var diff: FileDiff
    /// 仍待审阅的块 id。
    public var pending: Set<Int>
    /// 块级操作(保留 / 还原),参数为块 id。
    public var actions: [NativeDiffAction]
    /// 块头条标题。
    public var title: String
    /// 需要滚动到的块 id(变化时才滚动;nil 不滚动)。
    public var focusHunk: Int?

    public init(key: String, diff: FileDiff, pending: Set<Int>, actions: [NativeDiffAction], title: String, focusHunk: Int? = nil) {
        self.key = key
        self.diff = diff
        self.pending = pending
        self.actions = actions
        self.title = title
        self.focusHunk = focusHunk
    }
}

/// Agent 相关的编辑器钩子(行内审阅、⌘K 行内编辑、⌘L 引用选区)。
public struct NativeAgentHooks {
    public var review: NativeAgentReview?
    public var inlineEdit: NativeInlineEditGenerator?
    public var onReferenceSelection: ((NSRange) -> Void)?
    public var inlineSuggestion: NativeInlineSuggestionProvider?

    public init(review: NativeAgentReview? = nil, inlineEdit: NativeInlineEditGenerator? = nil, onReferenceSelection: ((NSRange) -> Void)? = nil,
                inlineSuggestion: NativeInlineSuggestionProvider? = nil) {
        self.inlineSuggestion = inlineSuggestion
        self.review = review
        self.inlineEdit = inlineEdit
        self.onReferenceSelection = onReferenceSelection
    }
}

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
    /// 语言智能回调与其版本号(版本变化才会重新装入,避免每次 SwiftUI 刷新都触发)。
    public var services = NativeLanguageServices()
    public var servicesKey = 0
    /// 光标/选区变化回调(状态栏「行 列」)。
    public var onCaretChange: ((EditorCaret) -> Void)?
    /// 文档变化(用户编辑或外部写入)回调,宿主据此防抖同步字符串镜像与脏标记。
    public var onEdited: ((DocumentChange) -> Void)?
    /// Agent 钩子(行内审阅、⌘K、⌘L)。
    public var agent = NativeAgentHooks()
    /// 外部操作句柄(宿主据此构建右键菜单);视图装入时绑定。
    public var handle: NativeEditorHandle?
    /// 首批语法着色完成并绘制后的回调(只触发一次)。
    public var onReady: (() -> Void)?
    /// 行尾内联提示(0 起始行号 → 文字),如 Git blame。
    public var inlineNote: ((Int) -> String?)?

    /// 返回带「就绪回调」的副本。
    /// - Parameter action: 首帧着色完成后调用
    public func onReady(_ action: @escaping () -> Void) -> NativeCodeEditor {
        var copy = self
        copy.onReady = action
        return copy
    }

    /// 返回带行尾内联提示(Git blame)的副本。
    /// - Parameter provider: 0 起始行号 → 提示文字;nil 不显示
    public func inlineNote(_ provider: ((Int) -> String?)?) -> NativeCodeEditor {
        var copy = self
        copy.inlineNote = provider
        return copy
    }

    /// 返回绑定了操作句柄的副本。
    /// - Parameter handle: 句柄
    public func handle(_ handle: NativeEditorHandle) -> NativeCodeEditor {
        var copy = self
        copy.handle = handle
        return copy
    }

    /// 返回带 Agent 钩子的副本。
    /// - Parameter hooks: 钩子
    public func agentHooks(_ hooks: NativeAgentHooks) -> NativeCodeEditor {
        var copy = self
        copy.agent = hooks
        return copy
    }

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
                services: NativeLanguageServices = NativeLanguageServices(), servicesKey: Int = 0,
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
        self.services = services
        self.servicesKey = servicesKey
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
        handle?.view = view
        view.onFirstHighlight = onReady
        sync(view, context.coordinator)
        return view
    }

    public func updateNSView(_ view: OMEditorView, context: Context) {
        if let handle, handle.view !== view { handle.view = view }
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
        view.languageController.teardown()
        view.model.detach()
    }

    /// 同步回调、标记与诊断。
    private func sync(_ view: OMEditorView, _ coordinator: Coordinator) {
        view.onTextChange = onEdited
        if coordinator.servicesKey != servicesKey {
            coordinator.servicesKey = servicesKey
            view.languageController.services = services
        }
        view.lineMarkers = markers
        view.inlineNote = inlineNote
        view.inlineEdit.generate = agent.inlineEdit
        view.inlineSuggestion.provider = agent.inlineSuggestion
        view.onReferenceSelection = agent.onReferenceSelection
        syncReview(view, coordinator)
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

    /// 同步 Agent 行内审阅:键变化才重建;被清空时移除 zone 与底色。
    private func syncReview(_ view: OMEditorView, _ coordinator: Coordinator) {
        guard let review = agent.review else {
            if coordinator.reviewKey != nil {
                coordinator.reviewKey = nil
                coordinator.reviewFocus = nil
                view.inlineReview.clear()
            }
            return
        }
        if coordinator.reviewKey != review.key {
            coordinator.reviewKey = review.key
            view.inlineReview.show(diff: review.diff, pending: review.pending, title: { _ in review.title }, actions: review.actions)
        }
        if let focus = review.focusHunk, coordinator.reviewFocus != focus {
            let isFirst = coordinator.reviewFocus == nil
            coordinator.reviewFocus = focus
            if !isFirst, let line = view.inlineReview.hunkLines[focus] { view.scrollToLine(max(line - 1, 0), centered: false) }
        }
    }

    /// 记录已应用状态,避免重复处理。
    @MainActor
    public final class Coordinator {
        var reviewKey: String?
        var reviewFocus: Int?
        var language: SyntaxLanguage?
        var revealedLine: Int?
        var servicesKey = 0
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
