// @author ixxxxoooo
// 跨文本块的连续选择中枢:会话流里每个文本叶子(`OMReadOnlyTextView`)都是一个「文本原子」,
// 中枢接管鼠标按下后的整个拖动过程(自己跑 `nextEvent` 跟踪循环,不靠本地事件监视器:
// NSTextView 自带的跟踪循环会吞掉拖动事件),把屏幕位置换算成 (原子序号, 字符偏移),
// 再由 `SelectionMath` 算出每个原子的选中范围,用布局管理器的临时属性画高亮(不改文本存储、不触发重排)。
//
// 设计要点:
// - 选择状态存成「原子键 + 偏移」,不依赖视图是否还在屏幕上:拖动期间滚出视口被卸载的叶子,
//   在卸载前把文本冻结进原子表,复制时照样拼进去;回到屏幕的叶子再按原子键重新上色。
// - 原子按「内容坐标」排序(自上而下、同行自左向右),键 = 叶子在内容坐标里的左上角,重新挂载后保持不变。
// - 每次拖动只遍历已挂载的叶子,与会话总长度无关。

import AppKit
import ChatKit
import DesignSystem
import OMLog

/// 跨叶子选择中枢(每个应用一个;选择范围限定在同一个最外层滚动视图内)。
@MainActor
final class SelectionHub {
    /// 全局唯一实例。
    static let shared = SelectionHub()

    /// 拖选触发自动滚动时通知会话流:这是用户主动滚动,不要再被「贴底跟随」拽回去。
    var onAutoScroll: (() -> Void)?

    /// 一个文本原子(会话流里的一个叶子)。
    @MainActor
    struct Atom {
        /// 稳定键:叶子左上角在内容坐标里的位置
        var key: String
        /// 叶子视图;被卸载后为 nil
        weak var view: OMReadOnlyTextView?
        /// 视图身份(用于换位时清掉旧键)
        var viewID: ObjectIdentifier
        /// 叶子在内容坐标(自上而下)里的整体边框
        var frame: CGRect
        /// 叶子被卸载时冻结的文本(已套用复制变换)
        var frozenText: String?
        /// 冻结时的长度(UTF-16)
        var frozenLength = 0

        /// 当前长度(UTF-16)。
        var length: Int { view?.textStorage?.length ?? frozenLength }

        /// 复制用文本:已套用叶子的复制变换(变换须保持长度不变,偏移才对得上)。
        var text: String {
            guard let view else { return frozenText ?? "" }
            let raw = view.string
            return view.copyTransform?(raw) ?? raw
        }
    }

    /// 已挂载的叶子(弱引用)。
    private let leaves = NSHashTable<OMReadOnlyTextView>.weakObjects()
    /// 画了高亮的叶子(弱引用)。
    private let highlighted = NSHashTable<OMReadOnlyTextView>.weakObjects()
    /// 原子表:键 → 原子。选择存续期间累积,开始新选择时清空。
    private var atoms: [String: Atom] = [:]
    /// 视图 → 它当前登记的原子键。
    private var viewKeys: [ObjectIdentifier: String] = [:]
    /// 选择范围限定的最外层滚动视图
    private weak var scope: NSScrollView?
    /// 选择的两端:(原子键, 偏移)
    private var anchor: (key: String, offset: Int)?
    private var focus: (key: String, offset: Int)?

    /// 当前是否有跨叶子(或叶子内)的中枢选择。
    var hasSelection: Bool {
        guard scope != nil, let anchor, let focus else { return false }
        return anchor.key != focus.key || anchor.offset != focus.offset
    }

    /// 选区背景色(读取主题令牌,随主题刷新)。
    private var selectionColor: NSColor { NSColor(OMColors.accent.opacity(0.28)) }

    // MARK: - 叶子登记

    /// 叶子进入窗口:登记;若当前有选择,下一轮把它该有的高亮补上。
    func leafDidMount(_ leaf: OMReadOnlyTextView) {
        leaves.add(leaf)
        guard hasSelection else { return }
        Task { @MainActor [weak self, weak leaf] in
            guard let self, let leaf, leaf.window != nil, Self.scopeScrollView(of: leaf) === self.scope else { return }
            self.refreshAtoms()
            self.applyHighlights()
        }
    }

    /// 叶子离开窗口:选择存续时把文本冻结进原子表,以便它滚出视口后仍能被复制。
    func leafDidLeave(_ leaf: OMReadOnlyTextView) {
        leaves.remove(leaf)
        highlighted.remove(leaf)
        leaf.hubRange = nil
        let id = ObjectIdentifier(leaf)
        guard let key = viewKeys.removeValue(forKey: id), var atom = atoms[key], atom.viewID == id else { return }
        if anchor != nil {
            atom.frozenLength = leaf.textStorage?.length ?? 0
            let raw = leaf.string
            atom.frozenText = leaf.copyTransform?(raw) ?? raw
            atom.view = nil
            atoms[key] = atom
        } else {
            atoms[key] = nil
        }
    }

    // MARK: - 选择生命周期

    /// 清除选择:去掉所有高亮、清空原子表、取消叶子自带的原生选区。
    func clearSelection() {
        for leaf in highlighted.allObjects { setHighlight(leaf, range: nil) }
        highlighted.removeAllObjects()
        for leaf in leaves.allObjects where leaf.selectedRange().length > 0 {
            leaf.setSelectedRange(NSRange(location: 0, length: 0))
        }
        anchor = nil
        focus = nil
        atoms.removeAll()
        viewKeys.removeAll()
    }

    /// 在叶子上按下鼠标:清掉旧选择,以按下处为起点。
    /// - Parameters:
    ///   - windowPoint: 按下位置(窗口坐标)
    ///   - leaf: 被按下的叶子
    /// - Returns: 是否成功建立起点
    @discardableResult
    func beginSelection(at windowPoint: NSPoint, from leaf: OMReadOnlyTextView) -> Bool {
        clearSelection()
        guard let outer = Self.scopeScrollView(of: leaf) else { return false }
        scope = outer
        refreshAtoms()
        guard let (key, offset) = position(at: windowPoint) else { return false }
        anchor = (key, offset)
        focus = (key, offset)
        return true
    }

    /// 把终点移到新位置并刷新高亮。
    /// - Parameter windowPoint: 鼠标位置(窗口坐标)
    func extendSelection(to windowPoint: NSPoint) {
        guard anchor != nil else { return }
        refreshAtoms()
        guard let (key, offset) = position(at: windowPoint) else { return }
        focus = (key, offset)
        applyHighlights()
    }

    /// 全选:选中当前已挂载的全部文本(窗口外尚未加载的回合不在其中)。
    /// - Parameter leaf: 发起全选的叶子
    func selectAll(from leaf: OMReadOnlyTextView) {
        clearSelection()
        guard let outer = Self.scopeScrollView(of: leaf) else { return }
        scope = outer
        refreshAtoms()
        let list = ordered()
        guard let first = list.first, let last = list.last else { return }
        anchor = (first.key, 0)
        focus = (last.key, last.length)
        applyHighlights()
    }

    /// 把当前选择拼成文本写入剪贴板。
    /// - Returns: 是否写入了内容
    @discardableResult
    func copySelection() -> Bool {
        let text = selectedText()
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// 当前选择的文本(来自模型文本,不依赖叶子是否仍在屏幕上)。
    func selectedText() -> String {
        guard let (list, ranges) = currentRanges() else { return "" }
        let sameRow = list.indices.map { $0 > 0 && abs(list[$0].frame.minY - list[$0 - 1].frame.minY) < 1 }
        return SelectionMath.joined(texts: list.map(\.text), ranges: ranges, sameRowAsPrevious: sameRow)
    }

    // MARK: - 鼠标跟踪

    /// 接管一次鼠标按下后的整个拖动过程(阻塞到鼠标抬起)。
    /// - Parameters:
    ///   - leaf: 被按下的叶子
    ///   - event: 按下事件
    /// - Returns: nil 表示无法接管(叶子不在滚动视图里等),调用方应回退到 NSTextView 原生行为;
    ///   否则返回是否发生了拖动(false 表示只是单击)
    func track(from leaf: OMReadOnlyTextView, with event: NSEvent) -> Bool? {
        guard let window = leaf.window, beginSelection(at: event.locationInWindow, from: leaf) else {
            Log.ui.debug("选择中枢无法接管 window=\(leaf.window != nil) scope=\(Self.scopeScrollView(of: leaf) != nil)")
            return nil
        }
        Log.ui.debug("选择中枢开始 atoms=\(atoms.count)")
        let start = event.locationInWindow
        var dragged = false
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while true {
            var location = start
            if let next = window.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: 1.0 / 30.0), inMode: .eventTracking, dequeue: true) {
                if next.type == .leftMouseUp { break }
                location = next.locationInWindow
                if !dragged, hypot(location.x - start.x, location.y - start.y) < 3 { continue }
                dragged = true
            } else {
                // 没有新事件:鼠标可能停在视口外沿,按住不动也要持续滚动
                guard dragged else { continue }
                location = window.mouseLocationOutsideOfEventStream
            }
            autoScroll(for: location)
            extendSelection(to: location)
        }
        Log.ui.debug("选择中枢结束 dragged=\(dragged) atoms=\(atoms.count) has=\(hasSelection)")
        if !dragged || !hasSelection { clearSelection() }
        return dragged
    }

    // MARK: - 几何

    /// 叶子所属的最外层滚动视图(跳过叶子自带的水平滚动视图)。嵌套的内层滚动区不算:选择要能跨出它。
    static func scopeScrollView(of leaf: NSView) -> NSScrollView? {
        var result: NSScrollView?
        var view = leaf.superview
        while let current = view {
            if let scroll = current as? NSScrollView, !(scroll is OMLeafScrollView) { result = scroll }
            view = current.superview
        }
        return result
    }

    /// 把窗口坐标换成内容坐标(自上而下)。
    private func contentPoint(_ windowPoint: NSPoint, in doc: NSView) -> NSPoint {
        let point = doc.convert(windowPoint, from: nil)
        return doc.isFlipped ? point : NSPoint(x: point.x, y: doc.bounds.height - point.y)
    }

    /// 把文档坐标的矩形换成内容坐标(自上而下)。
    private func contentRect(_ rect: NSRect, in doc: NSView) -> CGRect {
        doc.isFlipped ? rect : CGRect(x: rect.minX, y: doc.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 叶子的参照视图:不折行的叶子外面包着水平滚动视图,边框以它为准(文本视图本身可能比可见区域宽得多)。
    private func frameReference(of leaf: OMReadOnlyTextView) -> NSView {
        (leaf.enclosingScrollView as? OMLeafScrollView) ?? leaf
    }

    /// 用当前已挂载的叶子刷新原子表(位置、视图);已卸载的原子保持冻结。
    private func refreshAtoms() {
        guard let doc = scope?.documentView else { return }
        for leaf in leaves.allObjects {
            guard leaf.window != nil, (leaf.textStorage?.length ?? 0) > 0, Self.scopeScrollView(of: leaf) === scope else { continue }
            let reference = frameReference(of: leaf)
            let frame = contentRect(reference.convert(reference.bounds, to: doc), in: doc)
            let key = "\(Int(frame.minX.rounded())):\(Int(frame.minY.rounded()))"
            let id = ObjectIdentifier(leaf)
            if let old = viewKeys[id], old != key, atoms[old]?.viewID == id { atoms[old] = nil }
            viewKeys[id] = key
            atoms[key] = Atom(key: key, view: leaf, viewID: id, frame: frame)
        }
    }

    /// 原子按「内容坐标」排序:自上而下,同一行自左向右。
    private func ordered() -> [Atom] {
        atoms.values.sorted { lhs, rhs in
            let ly = Int(lhs.frame.minY.rounded()), ry = Int(rhs.frame.minY.rounded())
            return ly != ry ? ly < ry : lhs.frame.minX < rhs.frame.minX
        }
    }

    /// 屏幕位置 → (原子键, 偏移)。
    /// 落在某个叶子的行带上:取水平距离最近的叶子,偏移取点击处最近的插入点;落在叶子之间的空隙:算作下一个叶子的开头;
    /// 落在全部叶子之上/之下:算作第一个叶子的开头/最后一个叶子的末尾。
    private func position(at windowPoint: NSPoint) -> (String, Int)? {
        guard let doc = scope?.documentView else { return nil }
        let list = ordered()
        guard let first = list.first, let last = list.last else { return nil }
        let point = contentPoint(windowPoint, in: doc)
        let viewport = contentRect(doc.visibleRect, in: doc)
        // 可见的候选:只有当前真正显示在屏幕上的叶子参与命中
        var best: (index: Int, distance: CGFloat)?
        for (index, atom) in list.enumerated() {
            guard let view = atom.view, view.window != nil else { continue }
            // 可见部分 = 叶子边框 ∩ 滚动视口(NSView.visibleRect 不会被叶子自己的边界裁剪,不能直接用)
            let visible = atom.frame.intersection(viewport)
            guard !visible.isNull, !visible.isEmpty, visible.minY <= point.y, point.y < visible.maxY else { continue }
            let dx = point.x < visible.minX ? visible.minX - point.x : (point.x > visible.maxX ? point.x - visible.maxX : 0)
            if best == nil || dx < best?.distance ?? .infinity { best = (index, dx) }
        }
        if let best {
            let atom = list[best.index]
            return (atom.key, characterOffset(in: atom, windowPoint: windowPoint))
        }
        if point.y < first.frame.minY { return (first.key, 0) }
        if point.y >= last.frame.maxY { return (last.key, last.length) }
        if let next = list.first(where: { $0.frame.minY > point.y }) { return (next.key, 0) }
        return (last.key, last.length)
    }

    /// 点击处在叶子内最近的插入点偏移(点在叶子外侧时夹到边界)。
    private func characterOffset(in atom: Atom, windowPoint: NSPoint) -> Int {
        guard let view = atom.view else { return atom.length }
        var local = view.convert(windowPoint, from: nil)
        let visible = view.visibleRect
        local.x = min(max(local.x, visible.minX), max(visible.minX, visible.maxX - 1))
        local.y = min(max(local.y, 0), max(0, view.bounds.height - 1))
        return min(view.characterIndexForInsertion(at: local), atom.length)
    }

    // MARK: - 范围与高亮

    /// 当前选择在原子序列上的范围。
    private func currentRanges() -> ([Atom], [Range<Int>?])? {
        guard let anchor, let focus else { return nil }
        let list = ordered()
        guard let a = list.firstIndex(where: { $0.key == anchor.key }), let f = list.firstIndex(where: { $0.key == focus.key }) else { return nil }
        let ranges = SelectionMath.ranges(
            lengths: list.map(\.length),
            anchor: SelectionPoint(atom: a, offset: anchor.offset),
            focus: SelectionPoint(atom: f, offset: focus.offset))
        return (list, ranges)
    }

    /// 把选择画到已挂载的叶子上(范围没变的叶子不动)。
    private func applyHighlights() {
        guard let (list, ranges) = currentRanges() else { return }
        for (index, atom) in list.enumerated() {
            guard let view = atom.view else { continue }
            setHighlight(view, range: ranges[index])
        }
    }

    /// 给一个叶子设置高亮范围(临时属性,不改文本存储)。
    private func setHighlight(_ view: OMReadOnlyTextView, range: Range<Int>?) {
        let target = range.map { NSRange(location: $0.lowerBound, length: $0.count) }
        guard view.hubRange != target, let layout = view.layoutManager, let storage = view.textStorage else { return }
        if let old = view.hubRange, old.upperBound <= storage.length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        if let target, target.upperBound <= storage.length {
            layout.addTemporaryAttribute(.backgroundColor, value: selectionColor, forCharacterRange: target)
            highlighted.add(view)
        } else {
            highlighted.remove(view)
        }
        view.hubRange = target
    }

    // MARK: - 自动滚动

    /// 鼠标靠近或超出视口上下沿时滚动外层滚动视图(越靠外越快)。
    private func autoScroll(for windowPoint: NSPoint) {
        guard let scroll = scope, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let docHeight = doc.bounds.height
        let visible = contentRect(doc.visibleRect, in: doc)
        let y = contentPoint(windowPoint, in: doc).y
        let edge: CGFloat = 28
        var delta: CGFloat = 0
        if y < visible.minY + edge {
            delta = -min(48, 4 + (visible.minY + edge - y) * 0.6)
        } else if y > visible.maxY - edge {
            delta = min(48, 4 + (y - (visible.maxY - edge)) * 0.6)
        }
        guard delta != 0 else { return }
        let top = min(max(visible.minY + delta, 0), max(0, docHeight - visible.height))
        guard abs(top - visible.minY) > 0.5 else { return }
        let originY = doc.isFlipped ? top : docHeight - top - visible.height
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
        onAutoScroll?()
    }
}
