// @author ixxxxoooo
// 只读文本叶子的公共基类:会话流里所有「大量文字」的叶子(Markdown 文字段、代码块、工具输出、Diff、用户长消息)
// 共用的 NSTextView 子类与布局管理器。把它们从 SwiftUI `Text` 换成 TextKit 视图后:
// 1. 长文本排版走 TextKit(只绘制可见区域),不再让 SwiftUI 对整段富文本做布局;
// 2. 选择与复制由 NSTextView 原生处理(可跨多行,复制语义可定制);
// 3. 为后续跨消息选择中枢(`SelectionHub`)提供统一的叶子类型。

import AppKit
import DesignSystem

/// 整行底色标记(值为 `NSColor`):布局管理器据此把整行(含折行)铺满视图宽度。
let omLineFillKey = NSAttributedString.Key("OMLineFill")
/// 行号槽标记(值为 `OMGutterInfo`,设在每个段落上):布局管理器据此在左侧画行号槽、色条与符号。
let omGutterKey = NSAttributedString.Key("OMGutter")
/// 段落下方分隔线标记(值为 `NSColor`):布局管理器在该段最后一个行片段下方画一条贯穿视图宽度的 0.5pt 线(表格表头用)。
let omRuleBelowKey = NSAttributedString.Key("OMRuleBelow")

/// 一行的行号槽描述(Diff 用):行号、符号与配色。实现 `isEqual` 以便增量更新时比较属性。
final class OMGutterInfo: NSObject {
    /// 旧文件行号(为空时不画)
    let oldNumber: String
    /// 新文件行号(为空时不画)
    let newNumber: String
    /// 行符号(`+` / `−` / 空)
    let sign: String
    /// 行号槽总宽度(含色条与两侧内边距)
    let width: CGFloat
    /// 单个行号列宽度
    let columnWidth: CGFloat
    /// 行号槽底色
    let fill: NSColor
    /// 左侧色条颜色
    let bar: NSColor
    /// 行号文字颜色
    let numberColor: NSColor
    /// 符号文字颜色
    let signColor: NSColor
    /// 行号字体
    let font: NSFont
    /// 是否画新旧两列行号;`false` 只画 `newNumber` 一列(并排 Diff 的单侧)
    let twoColumns: Bool

    /// 创建行号槽描述。
    init(oldNumber: String, newNumber: String, sign: String, width: CGFloat, columnWidth: CGFloat, fill: NSColor, bar: NSColor,
         numberColor: NSColor, signColor: NSColor, font: NSFont, twoColumns: Bool) {
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.sign = sign
        self.width = width
        self.columnWidth = columnWidth
        self.fill = fill
        self.bar = bar
        self.numberColor = numberColor
        self.signColor = signColor
        self.font = font
        self.twoColumns = twoColumns
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? OMGutterInfo else { return false }
        return oldNumber == other.oldNumber && newNumber == other.newNumber && sign == other.sign && width == other.width
            && columnWidth == other.columnWidth && fill == other.fill && bar == other.bar && numberColor == other.numberColor
            && signColor == other.signColor && font == other.font && twoColumns == other.twoColumns
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(oldNumber)
        hasher.combine(newNumber)
        hasher.combine(sign)
        hasher.combine(width)
        return hasher.finalize()
    }
}

/// 叶子文本的布局管理器:在文字下方画整行底色与 Diff 行号槽。
final class OMLeafLayoutManager: NSLayoutManager {
    /// 整行底色铺多宽(文本视图当前宽度;由宿主视图布局时更新)
    var fillWidth: CGFloat = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let width = fillWidth
        guard width > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(omLineFillKey, in: charRange) { value, range, _ in
            guard let fill = value as? NSColor else { return }
            paintFill(fill, characterRange: range, origin: origin, width: width)
        }
        storage.enumerateAttribute(omRuleBelowKey, in: charRange) { value, range, _ in
            guard let color = value as? NSColor else { return }
            paintRule(color, characterRange: range, origin: origin, width: width)
        }
        storage.enumerateAttribute(omGutterKey, in: charRange) { value, range, _ in
            guard let info = value as? OMGutterInfo else { return }
            paintGutter(info, characterRange: range, origin: origin)
        }
    }

    /// 把一段字符对应的每个行片段铺满视图宽度(上下各外扩 0.5pt,消除小数行高的接缝)。
    private func paintFill(_ color: NSColor, characterRange: NSRange, origin: NSPoint, width: CGFloat) {
        let glyphRange = self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        color.setFill()
        enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
            NSRect(x: 0, y: fragment.minY + origin.y - 0.5, width: width, height: fragment.height + 1).fill()
        }
    }

    /// 在一段字符最后一个行片段的下方画分隔线(位于段后间距的中线)。
    private func paintRule(_ color: NSColor, characterRange: NSRange, origin: NSPoint, width: CGFloat) {
        let glyphRange = self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var bottom: CGFloat?
        enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in bottom = fragment.maxY }
        guard let bottom else { return }
        color.setFill()
        NSRect(x: 0, y: bottom + origin.y + 2.5, width: width, height: 0.5).fill()
    }

    /// 画一个段落的行号槽:整段高度的槽底色与色条,首个行片段上画行号与符号。
    private func paintGutter(_ info: OMGutterInfo, characterRange: NSRange, origin: NSPoint) {
        let glyphRange = self.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var first = true
        enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, lineGlyphs, _ in
            let slot = NSRect(x: 0, y: fragment.minY + origin.y - 0.5, width: info.width, height: fragment.height + 1)
            info.fill.setFill()
            slot.fill()
            info.bar.setFill()
            NSRect(x: 0, y: slot.minY, width: 3, height: slot.height).fill()
            guard first else { return }
            first = false
            let baseline = fragment.minY + self.location(forGlyphAt: lineGlyphs.location).y + origin.y
            let top = baseline - info.font.ascender
            self.drawNumbers(info, top: top)
        }
    }

    /// 在行号槽内画右对齐的行号与符号。
    private func drawNumbers(_ info: OMGutterInfo, top: CGFloat) {
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: info.font, .foregroundColor: info.numberColor]
        func drawRight(_ text: String, rightEdge: CGFloat) {
            guard !text.isEmpty else { return }
            let size = (text as NSString).size(withAttributes: numberAttributes)
            (text as NSString).draw(at: NSPoint(x: rightEdge - size.width, y: top), withAttributes: numberAttributes)
        }
        let start: CGFloat = 4
        if info.twoColumns {
            drawRight(info.oldNumber, rightEdge: start + info.columnWidth)
            drawRight(info.newNumber, rightEdge: start + info.columnWidth * 2)
        } else {
            drawRight(info.newNumber, rightEdge: start + info.columnWidth)
        }
        if !info.sign.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: info.font, .foregroundColor: info.signColor]
            let size = (info.sign as NSString).size(withAttributes: attributes)
            (info.sign as NSString).draw(at: NSPoint(x: info.width + (18 - size.width) / 2, y: top), withAttributes: attributes)
        }
    }
}

/// 只读、可选择的文本视图(TextKit 1)。所有叶子共用:滚轮交给外层滚动视图、复制语义可定制、单击回调。
class OMReadOnlyTextView: NSTextView {
    /// 文本存储由外部创建(NSTextView 不持有它),这里强引用以防被释放。
    var retainedStorage: NSTextStorage?
    /// 复制时对选中文本的变换(例如把软换行占位还原);为空则原样复制。
    var copyTransform: ((String) -> String)?
    /// 无选区的单击回调(拖选、双击、三击不触发):用户气泡据此「单击进入编辑」。
    var onPlainClick: (() -> Void)?

    required override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// 创建一个叶子文本视图。
    /// - Parameter layout: 布局管理器(决定绘制能力)
    /// - Returns: 只读可选、透明背景的文本视图;容器宽度由调用方按需设置
    static func make<T: OMReadOnlyTextView>(_ type: T.Type, layout: NSLayoutManager) -> T {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = type.init(frame: .zero, textContainer: container)
        view.retainedStorage = storage
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.focusRingType = .none
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.allowsUndo = false
        return view
    }

    override func copy(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0 else { return }
        var plain = (string as NSString).substring(with: selected)
        if let copyTransform { plain = copyTransform(plain) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    /// 滚轮交给外层滚动视图(叶子自身不滚动)。
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        super.mouseDown(with: event)
        // super 返回时鼠标已抬起:原地单击且没有产生选区,才算「单击」
        guard let onPlainClick, event.clickCount == 1, selectedRange().length == 0, let window else { return }
        let end = window.mouseLocationOutsideOfEventStream
        if hypot(end.x - start.x, end.y - start.y) < 4 { onPlainClick() }
    }

    /// 按给定容器宽度排版并返回已用尺寸(不含 `textContainerInset`)。
    /// - Parameter width: 文本容器宽度
    /// - Returns: 已用宽高(向上取整)
    func layoutSize(containerWidth width: CGFloat) -> CGSize {
        guard let container = textContainer, let layout = layoutManager else { return .zero }
        if container.size.width != width { container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.maxX), height: ceil(used.height))
    }
}
