// @author ygw
// 编辑器的语言智能扩展点(EditorKit 不依赖 LSPKit):诊断、悬停、跳转定义、补全。
// 应用层把 LSP 结果转换成这里的轻量类型并通过回调注入。

import AppKit

/// 编辑器内的一条诊断。偏移单位为 UTF-16(与 NSRange 一致)。
public struct EditorDiagnostic: Sendable, Equatable {
    public enum Severity: Int, Sendable, Equatable {
        case error = 1, warning, information, hint
    }

    public var range: NSRange
    public var severity: Severity
    public var message: String

    /// - Parameters:
    ///   - range: 受影响的文本范围
    ///   - severity: 严重程度
    ///   - message: 诊断文案
    public init(range: NSRange, severity: Severity, message: String) {
        self.range = range
        self.severity = severity
        self.message = message
    }
}

/// 一个补全候选。
public struct EditorCompletion: Sendable, Equatable {
    public var label: String
    /// 实际插入的文本
    public var insertText: String

    public init(label: String, insertText: String) {
        self.label = label
        self.insertText = insertText
    }
}

/// 语言智能回调集合。所有回调都在主线程调用,偏移为 UTF-16 偏移。
public struct EditorLanguageFeatures {
    /// 悬停:返回要展示的文本,无信息返回 nil。
    public var hover: (@MainActor (_ offset: Int) async -> String?)?
    /// 跳转定义(⌘ 点击或 F12)。
    public var definition: (@MainActor (_ offset: Int) -> Void)?
    /// 补全候选(⌃Space / Esc,或输入 `.` 后自动触发)。
    public var completion: (@MainActor (_ offset: Int) async -> [EditorCompletion])?

    public init(
        hover: (@MainActor (_ offset: Int) async -> String?)? = nil,
        definition: (@MainActor (_ offset: Int) -> Void)? = nil,
        completion: (@MainActor (_ offset: Int) async -> [EditorCompletion])? = nil
    ) {
        self.hover = hover
        self.definition = definition
        self.completion = completion
    }
}

/// 代码编辑器使用的文本视图:增加鼠标悬停驻留、⌘ 点击、F12 与异步补全。
@MainActor
public final class EditorTextView: NSTextView {
    /// 鼠标在某字符上驻留:(UTF-16 偏移, 该字符在视图坐标中的矩形)
    var onHoverDwell: ((Int, NSRect) -> Void)?
    /// 鼠标离开字符/视图或开始输入、滚动。
    var onHoverEnd: (() -> Void)?
    /// ⌘ 点击或 F12:请求跳转定义
    var onJumpToDefinition: ((Int) -> Void)?
    /// 异步取补全候选
    var completionProvider: ((Int) async -> [EditorCompletion])?
    /// 「在对话中引用选区」:传入非空选区的 UTF-16 范围
    var onReferenceSelection: ((NSRange) -> Void)?

    /// 获得/失去键盘焦点(Markdown 就地渲染据此决定是否展开光标所在块)
    var onFocusChange: ((Bool) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    private var dwellTask: Task<Void, Never>?
    private var hoverOffset: Int?
    private var pendingCompletions: [EditorCompletion] = []
    private var completionTask: Task<Void, Never>?
    private static let dwellDelay: Duration = .milliseconds(450)

    // MARK: 悬停

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.options.contains(.mouseMoved) { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard onHoverDwell != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let (offset, rect) = characterUnder(point) else {
            cancelHover()
            return
        }
        if hoverOffset == offset { return }
        cancelHover()
        hoverOffset = offset
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwellDelay)
            guard !Task.isCancelled, let self, self.hoverOffset == offset else { return }
            self.onHoverDwell?(offset, rect)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelHover()
    }

    public override func scrollWheel(with event: NSEvent) {
        cancelHover()
        super.scrollWheel(with: event)
    }

    /// 取消待触发的悬停并通知关闭悬浮窗。
    func cancelHover() {
        dwellTask?.cancel()
        dwellTask = nil
        if hoverOffset != nil {
            hoverOffset = nil
            onHoverEnd?()
        }
    }

    /// 视图坐标下鼠标所在的字符;位于行尾空白或文本之外返回 nil。
    private func characterUnder(_ point: NSPoint) -> (Int, NSRect)? {
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let insertion = characterIndexForInsertion(at: point)
        // 插入点位于字符边界:鼠标在字符左半边得到 c,右半边得到 c+1,两者都检查
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            guard let rect = rectOfCharacter(candidate), rect.insetBy(dx: -1, dy: 0).contains(point) else { continue }
            let char = (string as NSString).character(at: candidate)
            if let scalar = Unicode.Scalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            return (candidate, rect)
        }
        return nil
    }

    private func rectOfCharacter(_ index: Int) -> NSRect? {
        var actual = NSRange(location: 0, length: 0)
        let screen = firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: &actual)
        guard let window, screen != .zero else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return convert(inWindow, from: nil)
    }

    // MARK: 跳转定义

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), onJumpToDefinition != nil {
            let point = convert(event.locationInWindow, from: nil)
            if let (offset, _) = characterUnder(point) {
                onJumpToDefinition?(offset)
                return
            }
        }
        cancelHover()
        super.mouseDown(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        cancelHover()
        // F12:跳转到光标处符号的定义
        if event.keyCode == 111, let jump = onJumpToDefinition {
            jump(selectedRange().location)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: 引用选区

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if onReferenceSelection != nil, selectedRange().length > 0, let menu {
            let item = NSMenuItem(title: String(localized: "在对话中引用选区"), action: #selector(referenceSelection(_:)), keyEquivalent: "L")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func referenceSelection(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        onReferenceSelection?(range)
    }

    /// ⌘⇧L:引用选区(无选区或未接入时交还系统处理)。
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "l",
           onReferenceSelection != nil, selectedRange().length > 0, window?.firstResponder === self {
            referenceSelection(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 补全

    /// 先异步向语言服务器取候选,拿到后再走系统补全菜单。
    public override func complete(_ sender: Any?) {
        guard let provider = completionProvider else {
            super.complete(sender)
            return
        }
        completionTask?.cancel()
        let caret = selectedRange().location
        completionTask = Task { [weak self] in
            let items = await provider(caret)
            guard !Task.isCancelled, let self, !items.isEmpty, self.selectedRange().location == caret else { return }
            self.pendingCompletions = items
            self.presentSystemCompletion(sender)
        }
    }

    /// 调用系统补全菜单(闭包内不能直接使用 `super`,故单独封装)。
    private func presentSystemCompletion(_ sender: Any?) { super.complete(sender) }

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard !pendingCompletions.isEmpty else { return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) }
        let ns = string as NSString
        let prefix = charRange.length > 0 && NSMaxRange(charRange) <= ns.length ? ns.substring(with: charRange).lowercased() : ""
        index.pointee = 0
        return Self.menuStrings(for: pendingCompletions, prefix: prefix)
    }

    /// 按已输入前缀(忽略大小写)过滤并去重,返回补全菜单要显示的文本(即将插入的文本),最多 60 项。
    /// - Parameters:
    ///   - items: 候选
    ///   - prefix: 已输入的前缀
    public static func menuStrings(for items: [EditorCompletion], prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        return items
            .filter { lowered.isEmpty || $0.label.lowercased().hasPrefix(lowered) }
            .map(\.insertText)
            .filter { seen.insert($0).inserted }
            .prefix(60)
            .map { $0 }
    }
}
