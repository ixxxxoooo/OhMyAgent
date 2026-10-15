// @author ygw
// 基于 AppKit TextKit 2 的高性能代码编辑器:NSTextView + NSTextLayoutManager + NSTextContentStorage。

import AppKit

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
    /// 视口上下额外高亮的缓冲字符数。
    private static let highlightPadding = 12_000

    public let scrollView = NSScrollView()
    public let textView: NSTextView
    private let ruler: LineNumberRulerView
    private let engine = HighlightEngine()
    private var theme: EditorTheme
    private var language: SyntaxLanguage = .plain
    private var lineIndex = LineIndex(text: "")
    private var highlightedRange = NSRange(location: 0, length: 0)
    private var rebuildTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var generation = 0

    /// 性能探针:文本装载与首次布局耗时(秒)。
    public private(set) var lastLoadDuration: Double = 0

    /// 当前是否处于大文件模式。
    public private(set) var isLargeFileMode = false

    /// 用户编辑后回调(传出完整文本)。程序化 `setText` 不触发。
    public var onTextChange: ((String) -> Void)?

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
        self.textView = NSTextView(usingTextLayoutManager: true)
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
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.borderType = .noBorder
        // 滚动时保持纯色,避免合成开销
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = theme.background
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.delegate = self
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = isEditable
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        textView.font = theme.font
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

        textView.string = text
        textView.textColor = theme.foreground
        textView.font = theme.font
        // 先用文本长度粗判大文件(平均每行 40 字符),随后用精确行数修正
        let roughLarge = text.utf16.count / 40 > Self.largeFileLineThreshold
        applyLargeFileMode(roughLarge)
        textView.layoutManagerEnsureViewport()
        lastLoadDuration = (ContinuousClock.now - begin).seconds

        let engine = self.engine
        rebuildTask = Task { [weak self] in
            // 行索引与词法扫描均不在主线程
            let index = await Task.detached(priority: .userInitiated) { LineIndex(text: text) }.value
            _ = await engine.rebuild(text: text, language: language)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == current else { return }
                self.lineIndex = index
                self.ruler.lineIndex = index
                self.applyLargeFileMode(index.lineCount > Self.largeFileLineThreshold)
                self.scheduleHighlight()
            }
        }
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
        onTextChange?(text)
    }

    /// 滚动到指定行并选中该行。
    /// - Parameter line: 行号(1 起始,与 ACP 一致)
    public func reveal(line: Int) {
        guard let range = lineIndex.range(ofLine: max(line - 1, 0)) else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        scheduleHighlight()
    }

    /// 应用新主题。
    /// - Parameter theme: 主题
    public func apply(theme: EditorTheme) {
        self.theme = theme
        scrollView.backgroundColor = theme.background
        scrollView.contentView.backgroundColor = theme.background
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        textView.font = theme.font
        ruler.theme = theme
        highlightedRange = NSRange(location: 0, length: 0)
        scheduleHighlight()
    }

    // MARK: - 大文件模式

    private func applyLargeFileMode(_ large: Bool) {
        guard large != isLargeFileMode else { return }
        isLargeFileMode = large
        applyWrapping()
    }

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
    private func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            await self?.applyHighlightForViewport()
        }
    }

    /// 取视口(含缓冲)内的片段并作为渲染属性应用,不修改文本存储。
    private func applyHighlightForViewport() async {
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
    public func textDidChange(_ notification: Notification) {
        handleEdit()
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
            let pointInRuler = self.convert(NSPoint(x: 0, y: frame.minY + originY), from: textView)
            let label = NSAttributedString(string: String(line + 1), attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: pointInRuler.y + (frame.height - size.height) / 2))
            if let marker = self.lineMarkers[line] {
                let color: NSColor
                switch marker {
                case .added: color = .systemGreen
                case .removed: color = .systemRed
                case .modified: color = .systemOrange
                case .agent: color = .controlAccentColor
                }
                color.setFill()
                NSRect(x: 0, y: pointInRuler.y, width: 3, height: frame.height).fill()
            }
            return true
        }
    }
}
