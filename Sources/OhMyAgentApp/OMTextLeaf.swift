// @author ixxxxoooo
// 文本叶子的 SwiftUI 桥接:把一段 `NSAttributedString` 渲染进 `OMReadOnlyTextView`,按建议宽度自适应高度。
// 代码块、工具输出、Diff、用户长消息都通过它渲染;内容只在「签名」变化时重建,
// 流式追加时只替换尾部(见 `OMTextLeafCoordinator.apply`),不整段重排。

import AppKit
import DesignSystem
import SwiftUI

/// 叶子文本的版式配置。
struct OMTextLeafConfig: Equatable {
    /// 是否自动折行;`false` 时宽度由最长行决定,超出部分在叶子内水平滚动
    var wrap = true
    /// 文本四周内边距(对应 `textContainerInset`)
    var inset = NSSize.zero
    /// 额外的右侧留白(不属于内边距,如 Diff 的行尾 8pt)
    var trailingPadding: CGFloat = 0
    /// 不折行且内容超宽时,是否常驻显示水平滚动条(表格用:否则滚动条只在滚动时才出现,用户不知道可以横向滚动)
    var persistentScroller = false
}

/// 叶子宿主视图:自动折行时直接放文本视图;不折行时放进只允许水平滚动的滚动视图。
final class OMLeafHostView: NSView {
    /// 文本视图
    let textView: OMReadOnlyTextView
    /// 不折行时的水平滚动视图
    private(set) var scrollView: OMLeafScrollView?
    /// 文本视图应有的整体尺寸(含内边距;不折行时宽度可能大于宿主宽度)
    var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { needsLayout = true } }
    }

    /// 创建宿主视图。
    /// - Parameter wrap: 是否自动折行
    init(wrap: Bool) {
        textView = OMReadOnlyTextView.make(OMReadOnlyTextView.self, layout: OMLeafLayoutManager())
        super.init(frame: .zero)
        if wrap {
            addSubview(textView)
        } else {
            let scroll = OMLeafScrollView()
            scroll.documentView = textView
            addSubview(scroll)
            scrollView = scroll
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if let scrollView {
            scrollView.frame = bounds
            textView.frame = NSRect(x: 0, y: 0, width: max(bounds.width, contentSize.width), height: max(bounds.height, contentSize.height))
        } else {
            textView.frame = bounds
        }
        if let layout = textView.layoutManager as? OMLeafLayoutManager, layout.fillWidth != textView.frame.width {
            layout.fillWidth = textView.frame.width
            textView.needsDisplay = true
        }
    }
}

/// 只允许水平滚动的滚动视图:纵向滚轮交给外层(会话流)。
final class OMLeafScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        horizontalScroller = OMScroller()
        borderType = .noBorder
    }

    /// 是否常驻滚动条(仅内容超宽时出现,占用底部一条高度);否则为悬浮自动隐藏。
    var persistentScroller = false {
        didSet {
            guard persistentScroller != oldValue else { return }
            scrollerStyle = persistentScroller ? .legacy : .overlay
        }
    }

    required init?(coder: NSCoder) { nil }

    override func scrollWheel(with event: NSEvent) {
        // 横向为主的滚动留给自己,纵向为主的交给外层滚动视图
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

/// 叶子文本的渲染与测量状态(每个叶子一个,作为 `NSViewRepresentable` 的协调器)。
/// 抽出来是为了让「更新文本存储」的策略可以脱离 SwiftUI 单独测试。
@MainActor
final class OMTextLeafCoordinator {
    /// 上次渲染内容的签名
    private var renderedSignature: Int?
    /// 上次应用的外观签名(选区色)
    private var appliedSelection: [CGFloat]?
    /// 上次测量的宽度、尺寸与对应内容修订
    private var measuredWidth: CGFloat?
    private var measured = CGSize.zero
    private var measuredEdits = -1
    /// 实际改动文本存储的次数(测试用)
    private(set) var edits = 0
    /// 只替换尾部的增量更新次数(测试用)
    private(set) var incrementalUpdates = 0
    /// 整体重建次数(测试用)
    private(set) var fullRebuilds = 0
    /// 实际执行排版测量的次数(测试用)
    private(set) var measurePasses = 0
    /// 增量更新的最小文本长度:更短的文本整体替换更简单
    static let incrementalThreshold = 2_000

    /// 应用内容:签名没变什么都不做;否则构建并写入文本存储(追加型变化只替换尾部)。
    /// - Parameters:
    ///   - view: 文本视图
    ///   - signature: 内容与样式签名
    ///   - build: 构建富文本(仅签名变化时调用)
    func apply(to view: OMReadOnlyTextView, signature: Int, build: () -> NSAttributedString) {
        guard signature != renderedSignature, let storage = view.textStorage else { return }
        renderedSignature = signature
        let fresh = build()
        storage.beginEditing()
        if !replaceTail(storage, with: fresh) { storage.setAttributedString(fresh); fullRebuilds += 1 }
        storage.endEditing()
        edits += 1
        SelectionHub.shared.leafContentDidChange(view)
    }

    /// 新内容以旧内容为前缀(且前缀属性相同)时只替换尾部。
    /// - Returns: 是否已用增量方式更新
    private func replaceTail(_ storage: NSTextStorage, with fresh: NSAttributedString) -> Bool {
        let oldLength = storage.length
        guard oldLength >= Self.incrementalThreshold, fresh.length >= oldLength else { return false }
        // 去掉最后一小段再比较:流式时最后一行/最后一个 token 的着色可能在下一批改变
        let keep = oldLength - min(oldLength, 64)
        let old = storage.string as NSString
        let new = fresh.string as NSString
        guard old.substring(to: keep) == new.substring(to: keep) else { return false }
        let head = NSRange(location: 0, length: keep)
        guard storage.attributedSubstring(from: head).isEqual(to: fresh.attributedSubstring(from: head)) else { return false }
        storage.replaceCharacters(in: NSRange(location: keep, length: oldLength - keep),
                                  with: fresh.attributedSubstring(from: NSRange(location: keep, length: fresh.length - keep)))
        incrementalUpdates += 1
        return true
    }

    /// 应用选区颜色;没变时不重设。
    func applySelection(_ color: NSColor, to view: OMReadOnlyTextView) {
        let components = MarkdownTextRunRenderer.AppearanceSignature.components(color, appearance: view.effectiveAppearance)
        guard components != appliedSelection else { return }
        appliedSelection = components
        view.selectedTextAttributes = [.backgroundColor: color]
    }

    /// 测量所需尺寸,按 (宽度, 内容修订) 缓存。
    /// - Parameters:
    ///   - host: 宿主视图
    ///   - config: 版式配置
    ///   - proposedWidth: SwiftUI 提议的宽度
    /// - Returns: 叶子尺寸
    func measuredSize(_ host: OMLeafHostView, config: OMTextLeafConfig, proposedWidth: CGFloat?) -> CGSize {
        let proposed = proposedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // 完全没有宽度信息时用 480(与 Markdown 文字段一致),避免按 1pt 宽度排版得到巨大的虚高高度
        let width = proposed ?? measuredWidth ?? (host.bounds.width > 0 ? host.bounds.width : 480)
        if measuredEdits == edits, measuredWidth == width { return measured }
        let inset = config.inset
        let fit: CGSize
        if config.wrap {
            fit = host.textView.layoutSize(containerWidth: max(width - inset.width * 2 - config.trailingPadding, 1))
            host.contentSize = CGSize(width: width, height: fit.height + inset.height * 2)
        } else {
            // 不折行:容器取足够宽,宿主宽度等于建议宽度,内容宽度由最长行决定
            fit = host.textView.layoutSize(containerWidth: 1_000_000)
            host.contentSize = CGSize(width: fit.width + inset.width * 2 + config.trailingPadding, height: fit.height + inset.height * 2)
        }
        measurePasses += 1
        measuredWidth = width
        // 常驻滚动条且内容超宽:底部多留一条滚动条的高度,避免盖住最后一行
        let overflow = !config.wrap && config.persistentScroller && host.contentSize.width > width + 0.5
        let reserve = overflow ? OMScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        measured = CGSize(width: width, height: fit.height + inset.height * 2 + reserve)
        measuredEdits = edits
        return measured
    }
}

/// 把一段富文本放进叶子文本视图。
struct OMTextLeaf: NSViewRepresentable {
    /// 内容与样式的签名:变化时才重建富文本
    let signature: Int
    /// 版式配置
    var config = OMTextLeafConfig()
    /// 选区背景色
    var selectionColor: NSColor = NSColor(OMColors.accent.opacity(0.2))
    /// 复制时对选中文本的变换
    var copyTransform: ((String) -> String)?
    /// 无选区的单击回调
    var onPlainClick: (() -> Void)?
    /// 构建富文本(仅签名变化时调用)
    let build: @MainActor () -> NSAttributedString

    func makeCoordinator() -> OMTextLeafCoordinator { OMTextLeafCoordinator() }

    func makeNSView(context: Context) -> OMLeafHostView {
        let host = OMLeafHostView(wrap: config.wrap)
        host.textView.textContainerInset = config.inset
        host.textView.setAccessibilityLabel(String(localized: "消息正文"))
        return host
    }

    func updateNSView(_ host: OMLeafHostView, context: Context) {
        let view = host.textView
        view.copyTransform = copyTransform
        view.onPlainClick = onPlainClick
        host.scrollView?.persistentScroller = config.persistentScroller
        if view.textContainerInset != config.inset { view.textContainerInset = config.inset }
        context.coordinator.applySelection(selectionColor, to: view)
        context.coordinator.apply(to: view, signature: signature, build: build)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: OMLeafHostView, context: Context) -> CGSize? {
        context.coordinator.measuredSize(host, config: config, proposedWidth: proposal.width)
    }
}
