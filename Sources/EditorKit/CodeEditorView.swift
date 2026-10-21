// @author ixxxxoooo
// 基于 AppKit TextKit 2 的高性能代码编辑器:NSTextView + NSTextLayoutManager + NSTextContentStorage。

import AppKit
import DesignSystem
import OMLog

/// 行标记(用于 Diff 与 Agent 跟随)。
public enum LineMarker: Sendable {
    case added, removed, modified, agent
}

/// 代码编辑器视图(滚动视图 + 文本视图 + 行号标尺)。
@MainActor
public final class CodeEditorView: NSView {
    /// 超过该行数进入大文件模式:关闭自动换行,仅高亮视口附近。
    public static var largeFileLineThreshold: Int {
        let value = UserDefaults.standard.object(forKey: "editor.largeFileLines") as? Int ?? 20_000
        return min(max(value, 2_000), 200_000)
    }
    /// 不超过该长度的文本在装载时同步完成行索引与着色(首帧即是最终样子,切换文件不闪);更大的走后台。
    static let syncLoadLimit = 200_000
    /// 视口上下额外高亮的缓冲字符数。
    private static let highlightPadding = 12_000

    public let scrollView = NSScrollView()
    public let textView: EditorTextView
    private let ruler: LineNumberRulerView
    private let engine = HighlightEngine()
    var theme: EditorTheme
    /// 上次应用的字体族与字号偏好,用来判断偏好是否真的变了
    private var appliedFamily = EditorFontPrefs.preferredFamily
    private var appliedSize = EditorFontPrefs.preferredSize
    var language: SyntaxLanguage = .plain
    private var lineIndex = LineIndex(text: "")
    /// 已应用高亮的 UTF-16 范围(长度为 0 表示尚未高亮;测量工具据此判断首个高亮帧)。
    public internal(set) var highlightedRange = NSRange(location: 0, length: 0)
    private var rebuildTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    var generation = 0
    /// Markdown 渲染状态(见 `CodeEditorView+Markdown.swift`)
    var markdown = MarkdownRenderState()
    /// 查找条状态与结果(见 `CodeEditorView+Find.swift`)
    let findModel = EditorFindModel()
    var findHost: NSView?
    var findResults: [NSTextCheckingResult] = []
    var findRegex: NSRegularExpression?
    var findRefreshTask: Task<Void, Never>?
    /// Markdown 渲染模式:关闭 / 源码着色 / 就地渲染(仅 `.markdown` 语言有效)
    public var markdownMode: MarkdownEditorMode = .off {
        didSet { if oldValue != markdownMode { markdownModeDidChange() } }
    }

    /// 性能探针:文本装载与首次布局耗时(秒)。
    public private(set) var lastLoadDuration: Double = 0

    /// 当前是否处于大文件模式。
    public private(set) var isLargeFileMode = false

    /// 用户编辑后回调(传出完整文本)。程序化 `setText` 不触发。
    public var onTextChange: ((String) -> Void)?

    /// 语言智能回调(LSP 等);变更后立即接入文本视图。
    public var features = EditorLanguageFeatures() {
        didSet { wireFeatures() }
    }

    /// 右键菜单 / ⌘⇧L:把选区作为引用加入对话(传入 UTF-16 范围)。
    public var onReferenceSelection: ((NSRange) -> Void)? {
        didSet { textView.onReferenceSelection = onReferenceSelection }
    }

    /// 当前诊断(用于下划线、行号栏圆点与悬停提示)。
    public private(set) var diagnostics: [EditorDiagnostic] = []
    private var hoverPopover: NSPopover?
    private var hoverGeneration = 0
    private var autoCompleteTask: Task<Void, Never>?

    /// 行标记,变更后刷新标尺。
    public var lineMarkers: [Int: LineMarker] = [:] {
        didSet { ruler.lineMarkers = lineMarkers }
    }

    /// 创建编辑器。
    /// - Parameters:
    ///   - theme: 主题
    ///   - isEditable: 是否可编辑
    public init(theme: EditorTheme = .default, isEditable: Bool = true) {
        self.theme = theme
        // 显式使用 TextKit 2
        self.textView = EditorTextView(usingTextLayoutManager: true)
        self.ruler = LineNumberRulerView(scrollView: scrollView, theme: theme)
        super.init(frame: .zero)
        configure(isEditable: isEditable)
    }

    required init?(coder: NSCoder) { fatalError("不支持从 nib 创建") }

    /// 配置视图层级与文本视图属性。
    private func configure(isEditable: Bool) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // 图层底色:视图刚创建、尚未布局/绘制的首帧也是编辑器底色,不会闪白
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.borderType = .noBorder
        // 滚动时保持纯色,避免合成开销
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = theme.background
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.delegate = self
        textView.onFocusChange = { [weak self] focused in
            if focused, let self { CodeEditorView.lastFocused = self }
            self?.markdownSelectionDidChange(focus: focused)
        }
        // Markdown 所见即所得的基础交互(任务框/链接/列表续行)仅在就地渲染模式下启用,且文本需可编辑(任务框与续行会改文本)
        textView.markdownInteraction = { [weak self] in self?.markdownMode == .live && self?.language == .markdown }
        textView.markdownLayout = { [weak self] in self?.markdown.layout }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = isEditable
        // 查找由自绘查找条接管(`CodeEditorView+Find.swift`),不用系统查找栏
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        applyFontMetrics()
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        applyWrapping()

        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = ruler
        // 新系统不再自动把标尺的 clientView 指向文档视图,必须显式设置,否则行号永远不绘制
        ruler.clientView = textView
        scrollView.rulersVisible = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportDidChange),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // 设置页修改字体族/字号后,已打开的编辑器立即跟随(不依赖 SwiftUI 的刷新时机,后台保活的标签同样生效)
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification, object: nil
        )
        // 主题包/强调色变化:重新生成配色并整体重绘
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: ThemeRuntime.didChange, object: nil
        )
    }

    /// 主题变化后重新应用编辑器配色并清空高亮缓存。
    @objc private func themeDidChange() {
        CodeHighlighter.clearCache()
        apply(theme: .default)
        findThemeDidChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 公共 API

    /// 装载文本。耗时的行索引与词法扫描在后台完成。
    /// - Parameters:
    ///   - text: 文本
    ///   - language: 语言
    public func setText(_ text: String, language: SyntaxLanguage) {
        let begin = ContinuousClock.now
        generation += 1
        let current = generation
        self.language = language
        highlightedRange = NSRange(location: 0, length: 0)
        rebuildTask?.cancel()
        highlightTask?.cancel()

        // 新文本使旧诊断失效(属性随文本一起被清掉)
        diagnostics = []
        ruler.diagnosticLines = [:]
        closeHover()
        textView.string = text
        // 替换文本时新字符会继承旧字符的属性,显式去掉旧诊断的下划线
        if let storage = textView.textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.underlineStyle, range: all)
            storage.removeAttribute(.underlineColor, range: all)
        }
        textView.textColor = theme.foreground
        applyFontMetrics()
        // 先用文本长度粗判大文件(平均每行 40 字符),随后用精确行数修正
        let roughLarge = text.utf16.count / 40 > Self.largeFileLineThreshold
        applyLargeFileMode(roughLarge)
        let layoutStart = ContinuousClock.now
        textView.layoutManagerEnsureViewport()
        let layoutMs = Int((ContinuousClock.now - layoutStart).seconds * 1000)
        var syncLexMs = 0
        // 小文件:行索引、词法着色同步完成,避免先显示一帧无色文本、行号错位再跳变(切换文件时的闪动)
        if text.utf16.count <= Self.syncLoadLimit {
            let index = LineIndex(text: text)
            lineIndex = index
            ruler.lineIndex = index
            if !usesMarkdownStyling {
                let lexStart = ContinuousClock.now
                paintSyncHighlight(SimpleLexer.lex(text, language: language))
                syncLexMs = Int((ContinuousClock.now - lexStart).seconds * 1000)
            }
        }
        lastLoadDuration = (ContinuousClock.now - begin).seconds
        // 装载耗时分解:主线程总耗时、首屏排版、同步词法;超过 40ms 记 warning(同类文件反复慢时据此定位阶段)
        let loadMs = Int(lastLoadDuration * 1000)
        let loadFields = ["chars": "\(text.utf16.count)", "ms": "\(loadMs)", "layoutMs": "\(layoutMs)", "lexMs": "\(syncLexMs)", "largeFile": isLargeFileMode ? "yes" : "no"]
        if loadMs >= 40 { Log.perf.warning("编辑器装载偏慢", loadFields) } else { Log.perf.debug("编辑器装载", loadFields) }
        let backgroundSpan = Log.perf.span("编辑器后台索引与词法", warnMs: 200, ["chars": "\(text.utf16.count)"])

        let engine = self.engine
        rebuildTask = Task { [weak self] in
            // 行索引与词法扫描均不在主线程
            let index = await Task.detached(priority: .userInitiated) { LineIndex(text: text) }.value
            _ = await engine.rebuild(text: text, language: language)
            backgroundSpan.end(["lines": "\(index.lineCount)"])
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.lineIndex = index
                self.ruler.lineIndex = index
                self.applyLargeFileMode(index.lineCount > Self.largeFileLineThreshold)
                self.scheduleHighlight()
            }
        }
        markdown.layout = nil
        if usesMarkdownStyling, text.utf16.count <= Self.syncLoadLimit / 2 {
            markdown.task?.cancel()
            applyMarkdown(MarkdownLiveRenderer.layout(for: text))
        } else {
            scheduleMarkdownRender(delay: .zero)
        }
        scheduleFindRefresh()
    }

    /// 把整篇文本的词法片段一次性写成前景色,并标记全文已高亮。
    /// - Parameter spans: 词法扫描结果
    private func paintSyncHighlight(_ spans: [SyntaxSpan]) {
        guard let storage = textView.textStorage else { return }
        let docRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: theme.foreground, range: docRange)
        for span in spans {
            guard let color = theme.colors[span.kind] else { continue }
            let range = NSIntersectionRange(NSRange(location: span.location, length: span.length), docRange)
            if range.length > 0 { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        storage.endEditing()
        highlightedRange = docRange
    }

    /// 用户编辑后:同步更新行索引(小文件)、防抖重做词法并回调。
    fileprivate func handleEdit() {
        let text = textView.string
        generation += 1
        let current = generation
        let language = self.language
        let engine = self.engine
        if text.utf16.count <= 300_000 {
            let index = LineIndex(text: text)
            lineIndex = index
            ruler.lineIndex = index
        } else {
            ruler.needsDisplay = true
        }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let index = await Task.detached(priority: .userInitiated) { LineIndex(text: text) }.value
            _ = await engine.rebuild(text: text, language: language)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.lineIndex = index
                self.ruler.lineIndex = index
                self.applyLargeFileMode(index.lineCount > Self.largeFileLineThreshold)
                self.highlightedRange = NSRange(location: 0, length: 0)
                self.scheduleHighlight()
            }
        }
        closeHover()
        markdown.layout = nil
        scheduleMarkdownRender(delay: .milliseconds(60))
        onTextChange?(text)
        scheduleAutoCompletion()
        scheduleFindRefresh()
    }

    /// 滚动到指定行并选中该行。
    /// - Parameter line: 行号(1 起始,与 ACP 一致)
    public func reveal(line: Int) {
        guard let range = lineIndex.range(ofLine: max(line - 1, 0)) else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        scheduleHighlight()
    }

    // MARK: - 语言智能

    /// 接入悬停/跳转/补全回调。
    private func wireFeatures() {
        textView.completionProvider = features.completion
        if features.definition != nil {
            textView.onJumpToDefinition = { [weak self] offset in self?.features.definition?(offset) }
        } else {
            textView.onJumpToDefinition = nil
        }
        textView.onHoverEnd = { [weak self] in self?.closeHover() }
        if features.hover != nil || !diagnostics.isEmpty {
            textView.onHoverDwell = { [weak self] offset, rect in self?.showHover(at: offset, rect: rect) }
        } else {
            textView.onHoverDwell = nil
        }
    }

    /// 设置诊断:用彩色下划线标出范围,行号栏显示最严重级别的圆点。
    /// - Parameter newValue: 诊断列表(越界范围会被夹取)
    public func setDiagnostics(_ newValue: [EditorDiagnostic]) {
        guard newValue != diagnostics else { return }
        diagnostics = newValue
        wireFeatures()
        guard let storage = textView.textStorage else { return }
        let total = storage.length
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: total))
        storage.removeAttribute(.underlineColor, range: NSRange(location: 0, length: total))
        var worstByLine: [Int: EditorDiagnostic.Severity] = [:]
        for diagnostic in newValue {
            let start = min(max(diagnostic.range.location, 0), total)
            // 空范围(服务器只给出一个点)时向后扩展到整个标识符,至少标出一个字符
            let length = diagnostic.range.length > 0 ? diagnostic.range.length : Self.wordLength(in: storage.string as NSString, from: start)
            let range = NSIntersectionRange(NSRange(location: start, length: length), NSRange(location: 0, length: total))
            if range.length > 0 {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.underlineColor, value: Self.color(for: diagnostic.severity), range: range)
            }
            let line = lineIndex.line(containing: start)
            if let existing = worstByLine[line], existing.rawValue <= diagnostic.severity.rawValue { continue }
            worstByLine[line] = diagnostic.severity
        }
        storage.endEditing()
        ruler.diagnosticLines = worstByLine
    }

    /// 从某偏移开始的标识符长度(字母数字下划线);不是标识符则为 1。
    static func wordLength(in text: NSString, from start: Int) -> Int {
        var end = start
        while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)),
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { end += 1 }
        return max(end - start, 1)
    }

    static func color(for severity: EditorDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return NSColor(OMColors.danger)
        case .warning: return NSColor(OMColors.warning)
        case .information: return NSColor(OMColors.accent2)
        case .hint: return NSColor(OMColors.tertiaryText)
        }
    }

    /// 弹出悬停提示:先列出覆盖该位置的诊断,再追加语言服务器的 hover 文本。
    private func showHover(at offset: Int, rect: NSRect) {
        hoverGeneration += 1
        let generation = hoverGeneration
        let covering = diagnostics.filter { NSLocationInRange(offset, $0.range) || ($0.range.length == 0 && $0.range.location == offset) }
        let hover = features.hover
        Task { [weak self] in
            var parts = covering.map { "\(Self.symbol(for: $0.severity)) \($0.message)" }
            if let hover, let text = await hover(offset) { parts.append(Self.plainText(fromMarkdown: text)) }
            guard let self, self.hoverGeneration == generation, !parts.isEmpty else { return }
            self.presentHover(parts.joined(separator: "\n\n"), rect: rect)
        }
    }

    private static func symbol(for severity: EditorDiagnostic.Severity) -> String {
        switch severity {
        case .error: return "⛔"
        case .warning: return "⚠️"
        case .information: return "ℹ️"
        case .hint: return "💡"
        }
    }

    /// 去掉 Markdown 围栏标记,保留代码与说明文字(悬浮窗用等宽纯文本展示)。
    public static func plainText(fromMarkdown markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentHover(_ text: String, rect: NSRect) {
        closeHoverPopover()
        let label = NSTextField(wrappingLabelWithString: String(text.prefix(2_000)))
        label.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 480
        label.setAccessibilityLabel(text)
        let content = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        hoverPopover = popover
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }

    private func closeHover() {
        hoverGeneration += 1
        closeHoverPopover()
    }

    private func closeHoverPopover() {
        hoverPopover?.close()
        hoverPopover = nil
    }

    /// 输入 `.` 后稍作停顿自动弹出补全。
    private func scheduleAutoCompletion() {
        autoCompleteTask?.cancel()
        guard features.completion != nil else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret > 0, caret <= ns.length, ns.character(at: caret - 1) == 0x2E else { return }
        autoCompleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.textView.complete(nil)
        }
    }

    /// 应用新主题。
    /// - Parameter theme: 主题
    public func apply(theme: EditorTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.cgColor
        scrollView.backgroundColor = theme.background
        scrollView.contentView.backgroundColor = theme.background
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        applyFontMetrics()
        ruler.theme = theme
        highlightedRange = NSRange(location: 0, length: 0)
        scheduleHighlight()
        markdown.layout = nil
        scheduleMarkdownRender(delay: .zero)
    }

    /// 偏好变化通知可能在任意线程投递:切回主线程后再比较字体。
    @objc nonisolated private func defaultsDidChange() {
        Task { @MainActor [weak self] in self?.refreshFontFromPrefs() }
    }

    /// 字体族或字号偏好变化时更新字体与行高;颜色等其他主题项保持不变。
    /// 通知会在任何偏好变化时触发,所以先比较偏好值,没变就直接返回。
    func refreshFontFromPrefs() {
        let family = EditorFontPrefs.preferredFamily
        let size = EditorFontPrefs.preferredSize
        guard family != appliedFamily || size != appliedSize else { return }
        appliedFamily = family
        appliedSize = size
        var next = theme
        next.font = EditorFontPrefs.font(family: family, size: size)
        apply(theme: next)
    }

    /// 把主题里的字体与行高写入文本视图、默认段落样式和已有文本。
    /// Markdown 样式由 `MarkdownStyler` 逐块铺属性,此处只处理非 Markdown 内容。
    private func applyFontMetrics() {
        let style = theme.paragraphStyle
        textView.font = theme.font
        textView.defaultParagraphStyle = style
        var typing = textView.typingAttributes
        typing[.font] = theme.font
        typing[.paragraphStyle] = style
        textView.typingAttributes = typing
        guard !usesMarkdownStyling, let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
    }

    // MARK: - 大文件模式

    private func applyLargeFileMode(_ large: Bool) {
        guard large != isLargeFileMode else { return }
        isLargeFileMode = large
        applyWrapping()
    }

    /// 当前实际是否按自动换行布局(用户偏好或大文件模式强制)。
    public var isWrapping: Bool { wrapsLines || isLargeFileMode }

    /// 是否自动换行。M0 实测:容器宽度超过可视宽度(横向滚动)时,TextKit 2 需要全量布局,
    /// 5 万行装载 ≈ 0.8s、输入 ≈ 115ms;自动换行装载 ≈ 25ms、输入 ≈ 1.2ms。
    /// 因此默认换行,且大文件模式强制换行。
    public var wrapsLines = UserDefaults.standard.object(forKey: "editor.wrap") as? Bool ?? true {
        didSet { applyWrapping() }
    }

    /// 配置换行策略。大文件模式一律换行以保证性能。
    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        if wrapsLines || isLargeFileMode {
            container.widthTracksTextView = true
            container.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            scrollView.hasHorizontalScroller = true
        }
    }

    // MARK: - 视口高亮

    @objc private func viewportDidChange() {
        ruler.needsDisplay = true
        scheduleHighlight()
    }

    /// 防抖调度视口高亮。
    func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            await self?.applyHighlightForViewport()
        }
    }

    /// 取视口(含缓冲)内的片段并作为渲染属性应用,不修改文本存储。
    private func applyHighlightForViewport() async {
        // Markdown 由块布局统一着色,不走词法高亮
        if usesMarkdownStyling { return }
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let viewportRange = layoutManager.textViewportLayoutController.viewportRange else { return }
        let visible = contentStorage.nsRange(viewportRange)
        let total = (textView.string as NSString).length
        let start = max(visible.location - Self.highlightPadding, 0)
        let end = min(visible.location + visible.length + Self.highlightPadding, total)
        let desired = NSRange(location: start, length: max(end - start, 0))
        // 已覆盖则无需重复应用
        if highlightedRange.length > 0,
           highlightedRange.location <= visible.location,
           NSMaxRange(highlightedRange) >= NSMaxRange(visible) { return }

        let current = generation
        let spans = await engine.spans(in: desired)
        guard generation == current, !Task.isCancelled else { return }

        // 直接写入文本存储的前景色属性:TextKit 2 的渲染属性在新系统上不会被绘制。
        // 属性变更不改变字符串,不会触发 textDidChange 与撤销登记。
        guard let storage = textView.textStorage else { return }
        let paintSpan = Log.perf.span("视口高亮应用", warnMs: 30, quiet: true, ["spans": "\(spans.count)", "chars": "\(desired.length)"])
        defer { paintSpan.end() }
        let docRange = NSRange(location: 0, length: storage.length)
        let resetRange = NSIntersectionRange(NSUnionRange(highlightedRange, desired), docRange)
        storage.beginEditing()
        if resetRange.length > 0 { storage.addAttribute(.foregroundColor, value: theme.foreground, range: resetRange) }
        for span in spans {
            guard let color = theme.colors[span.kind] else { continue }
            let range = NSIntersectionRange(NSRange(location: span.location, length: span.length), docRange)
            if range.length > 0 { storage.addAttribute(.foregroundColor, value: color, range: range) }
        }
        storage.endEditing()
        highlightedRange = desired
    }
}

// MARK: - 文本编辑回调

extension CodeEditorView: NSTextViewDelegate {
    /// 新输入的字符不继承诊断下划线。
    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        var attributes = textView.typingAttributes
        if attributes[.underlineStyle] != nil || attributes[.underlineColor] != nil {
            attributes[.underlineStyle] = nil
            attributes[.underlineColor] = nil
            textView.typingAttributes = attributes
        }
        resetMarkdownTypingAttributes()
        return true
    }

    public func textDidChange(_ notification: Notification) {
        handleEdit()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        markdownSelectionDidChange()
    }
}

// MARK: - 工具

extension NSTextContentStorage {
    /// 将 UTF-16 范围转换为 NSTextRange。
    /// - Parameter range: NSRange
    /// - Returns: 转换结果,越界返回 nil
    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// 将 NSTextRange 转换为 UTF-16 范围。
    /// - Parameter textRange: 文本范围
    /// - Returns: NSRange
    func nsRange(_ textRange: NSTextRange) -> NSRange {
        let location = offset(from: documentRange.location, to: textRange.location)
        let length = offset(from: textRange.location, to: textRange.endLocation)
        return NSRange(location: location, length: length)
    }
}

private extension NSTextView {
    /// 触发视口布局,使首屏立即可见。
    func layoutManagerEnsureViewport() {
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.textViewportLayoutController.layoutViewport()
    }
}

public extension Duration {
    /// 转换为秒。
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - 行号标尺

/// 行号标尺:仅绘制视口内片段,行号通过二分查找获得。
@MainActor
final class LineNumberRulerView: NSRulerView {
    var lineIndex = LineIndex(text: "") { didSet { needsDisplay = true } }
    var theme: EditorTheme { didSet { needsDisplay = true } }
    var lineMarkers: [Int: LineMarker] = [:] { didSet { needsDisplay = true } }
    /// 每行最严重的诊断级别(绘制圆点)
    var diagnosticLines: [Int: EditorDiagnostic.Severity] = [:] { didSet { needsDisplay = true } }

    init(scrollView: NSScrollView, theme: EditorTheme) {
        self.theme = theme
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 52
        clipsToBounds = true
        clientView = scrollView.documentView
    }

    required init(coder: NSCoder) { fatalError("不支持从 nib 创建") }

    override var isOpaque: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // macOS 14+ 视图默认不再裁剪到自身边界;只在标尺自己的范围内绘制,否则灰色底会盖住整个编辑区
        theme.gutterBackground.setFill()
        bounds.fill()
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let viewportRange = layoutManager.textViewportLayoutController.viewportRange else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: theme.gutterForeground,
        ]
        let originY = textView.textContainerOrigin.y
        layoutManager.enumerateTextLayoutFragments(from: viewportRange.location, options: [.ensuresLayout]) { fragment in
            if fragment.rangeInElement.location.compare(viewportRange.endLocation) != .orderedAscending { return false }
            let nsRange = contentStorage.nsRange(fragment.rangeInElement)
            let line = self.lineIndex.line(containing: nsRange.location)
            // 仅在逻辑行首绘制,折行片段不重复编号
            guard self.lineIndex.lineStarts[line] == nsRange.location else { return true }
            let frame = fragment.layoutFragmentFrame
            // 折叠的行(Markdown 围栏标记行)不编号,避免与下一行重叠
            if frame.height < 6 { return true }
            let pointInRuler = self.convert(NSPoint(x: 0, y: frame.minY + originY), from: textView)
            let label = NSAttributedString(string: String(line + 1), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: pointInRuler.y + (frame.height - size.height) / 2))
            if let severity = self.diagnosticLines[line] {
                CodeEditorView.color(for: severity).setFill()
                NSBezierPath(ovalIn: NSRect(x: 6, y: pointInRuler.y + (frame.height - 6) / 2, width: 6, height: 6)).fill()
            }
            if let marker = self.lineMarkers[line] {
                let color: NSColor
                switch marker {
                case .added: color = NSColor(OMColors.success)
                case .removed: color = NSColor(OMColors.danger)
                case .modified: color = NSColor(OMColors.warning)
                case .agent: color = .controlAccentColor
                }
                color.setFill()
                NSRect(x: 0, y: pointInRuler.y, width: 3, height: frame.height).fill()
            }
            return true
        }
    }
}
