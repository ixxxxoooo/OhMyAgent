// @author ixxxxoooo
// 原生编辑视图的鼠标与滚轮:点击定位、双击选词、三击选行、拖选(含自动滚动)、⌥ 多光标、⌥⇧ 列选择、滚动条拖动、行号栏点击。

import AppKit
import EditorCore

extension OMEditorView {
    // MARK: 滚轮

    public override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= lineHeight
            dy *= lineHeight
        }
        // ⇧ + 滚轮 = 横向滚动。
        if event.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        if wrapsLines { dx = 0 }
        // 主轴锁定:纵向为主时忽略轻微的横向抖动,滚动更稳。
        if abs(dx) < abs(dy) * 0.35 { dx = 0 } else if abs(dy) < abs(dx) * 0.35 { dy = 0 }
        scrollBy(dx: -dx, dy: -dy)
    }

    // MARK: 光标样式

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(textArea, cursor: .iBeam)
        addCursorRect(NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height), cursor: .arrow)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 靠近右/下边缘时显示滚动条,方便抓取。
        if point.x > bounds.width - 14 || point.y > bounds.height - 14 { showScrollbars() }
    }

    // MARK: 按下

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point
        model.document.breakUndoCoalescing()
        if beginScrollbarDrag(at: point) { return }
        if stickyClick(at: point) { return }
        if point.x < gutterWidth { gutterClick(at: point, event: event); return }

        let offset = offset(at: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let rope = model.document.snapshot
        switch event.clickCount {
        case 1:
            if flags.contains(.command), !flags.contains(.option) {
                onCommandClick?(offset)
                return
            }
            if flags.contains(.option), flags.contains(.shift) {
                let position = rope.position(at: offset)
                let column = model.metrics.column(inLine: rope.slice(rope.lineRange(position.line) ?? TextSpan(location: 0, length: 0)), atOffset: position.column)
                columnAnchor = (position.line, column)
                dragMode = .column
                model.setSelections(SelectionSet([Selection(caret: offset)]))
            } else if flags.contains(.option) {
                dragMode = .character
                dragAnchor = TextSpan(location: offset, length: 0)
                model.setSelections(model.selections.adding(Selection(caret: offset)))
            } else if flags.contains(.shift) {
                let primary = model.selections.primary
                dragMode = .character
                dragAnchor = TextSpan(location: primary.anchor, length: 0)
                model.setSelections(SelectionSet([Selection(anchor: primary.anchor, head: offset)]))
            } else {
                dragMode = .character
                dragAnchor = TextSpan(location: offset, length: 0)
                model.setSelections(SelectionSet([Selection(caret: offset)]))
            }
        case 2:
            let word = CursorMotion.wordRange(at: offset, in: rope)
            dragMode = .word
            dragAnchor = word
            apply(selection: Selection(anchor: word.location, head: word.upperBound), additive: flags.contains(.option))
        default:
            let line = lineSpan(containing: offset)
            dragMode = .line
            dragAnchor = line
            apply(selection: Selection(anchor: line.location, head: line.upperBound), additive: flags.contains(.option))
        }
        startAutoscrollIfNeeded()
    }

    /// 设置/追加选区。
    private func apply(selection: Selection, additive: Bool) {
        if additive { model.setSelections(model.selections.adding(selection)) } else { model.setSelections(SelectionSet([selection])) }
    }

    /// 包含偏移的整行区间(含换行符)。
    func lineSpan(containing offset: Int) -> TextSpan {
        let rope = model.document.snapshot
        let line = rope.line(containing: offset)
        let start = rope.lineStart(line)
        let end = line + 1 < rope.lineCount ? rope.lineStart(line + 1) : rope.length
        return TextSpan(location: start, length: end - start)
    }

    // MARK: 拖动

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseLocation = point
        if let drag = scrollbarDrag { dragScrollbar(drag, to: point); return }
        updateDragSelection(at: point)
        startAutoscrollIfNeeded()
    }

    public override func mouseUp(with event: NSEvent) {
        dragMode = .none
        columnAnchor = nil
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        if scrollbarDrag != nil {
            scrollbarDrag = nil
            showScrollbars()
            needsDisplay = true
        }
    }

    /// 按拖动模式更新选区。
    func updateDragSelection(at point: CGPoint) {
        let rope = model.document.snapshot
        let offset = offset(at: point)
        switch dragMode {
        case .none:
            return
        case .character:
            var list = model.selections.selections
            let selection = Selection(anchor: dragAnchor.location, head: offset)
            if list.count > 1, model.selections.primaryIndex < list.count {
                list[model.selections.primaryIndex] = selection
                model.setSelections(SelectionSet(list, primary: model.selections.primaryIndex))
            } else {
                model.setSelections(SelectionSet([selection]))
            }
        case .word:
            let word = CursorMotion.wordRange(at: offset, in: rope)
            let lower = min(word.location, dragAnchor.location)
            let upper = max(word.upperBound, dragAnchor.upperBound)
            let forward = offset >= dragAnchor.location
            model.setSelections(SelectionSet([forward ? Selection(anchor: dragAnchor.location, head: upper) : Selection(anchor: dragAnchor.upperBound, head: lower)]))
        case .line:
            let line = lineSpan(containing: offset)
            let forward = line.location >= dragAnchor.location
            model.setSelections(SelectionSet([forward ? Selection(anchor: dragAnchor.location, head: line.upperBound) : Selection(anchor: dragAnchor.upperBound, head: line.location)]))
        case .column:
            guard let anchor = columnAnchor else { return }
            let position = rope.position(at: offset)
            // 列由鼠标 x 坐标直接换算,可以超出行尾(与 Monaco 一致,短行夹取到行尾)。
            let column = max(((point.x - textOriginX) / columnWidth).rounded(), 0)
            model.setSelections(ColumnSelection.make(rope: rope, anchorLine: anchor.line, anchorColumn: anchor.column,
                                                    headLine: position.line, headColumn: Double(column), metrics: model.metrics))
        }
    }

    /// 拖到视图外时按距离匀速滚动并继续扩展选区。
    func startAutoscrollIfNeeded() {
        guard dragMode != .none else { return }
        let outside = lastMouseLocation.y < 0 || lastMouseLocation.y > bounds.height
            || lastMouseLocation.x < gutterWidth || lastMouseLocation.x > textArea.maxX
        guard outside else {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
            return
        }
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragMode != .none else { return }
                let p = self.lastMouseLocation
                let dy: CGFloat = p.y < 0 ? p.y : (p.y > self.bounds.height ? p.y - self.bounds.height : 0)
                let dx: CGFloat = p.x < self.gutterWidth ? p.x - self.gutterWidth : (p.x > self.textArea.maxX ? p.x - self.textArea.maxX : 0)
                self.scrollBy(dx: dx * 0.5, dy: dy * 0.5)
                self.updateDragSelection(at: p)
            }
        }
    }

    // MARK: 行号栏

    private func gutterClick(at point: CGPoint, event: NSEvent) {
        let offset = offset(at: CGPoint(x: gutterWidth + 1, y: point.y))
        let line = model.document.snapshot.line(containing: offset)
        if point.x < 12 { onGutterClick?(line); return }
        // 点击行号 = 选中整行;拖动可继续扩展整行选择。
        let span = lineSpan(containing: offset)
        dragMode = .line
        dragAnchor = span
        model.setSelections(SelectionSet([Selection(anchor: span.location, head: span.upperBound)]))
    }

    // MARK: 滚动条拖动

    private func beginScrollbarDrag(at point: CGPoint) -> Bool {
        guard ProcessInfo.processInfo.systemUptime < scrollbarVisibleUntil || point.x > bounds.width - 12 else { return false }
        if let thumb = verticalThumbRect(), point.x >= bounds.width - 12 {
            if thumb.contains(point) {
                scrollbarDrag = ScrollbarDrag(vertical: true, grabOffset: point.y - thumb.minY)
            } else {
                // 点轨道:翻一页。
                scrollBy(dx: 0, dy: point.y < thumb.minY ? -bounds.height * 0.9 : bounds.height * 0.9)
            }
            needsDisplay = true
            return true
        }
        if let thumb = horizontalThumbRect(), point.y >= bounds.height - 12 {
            if thumb.contains(point) { scrollbarDrag = ScrollbarDrag(vertical: false, grabOffset: point.x - thumb.minX) }
            needsDisplay = true
            return true
        }
        return false
    }

    private func dragScrollbar(_ drag: ScrollbarDrag, to point: CGPoint) {
        if drag.vertical, let thumb = verticalThumbRect() {
            let track = bounds.height - thumb.height
            guard track > 0 else { return }
            let fraction = min(max((point.y - drag.grabOffset) / track, 0), 1)
            scroll(y: fraction * maxScrollY)
        } else if let thumb = horizontalThumbRect() {
            let track = textArea.width - thumb.width
            guard track > 0 else { return }
            let fraction = min(max((point.x - gutterWidth - drag.grabOffset) / track, 0), 1)
            scroll(toX: fraction * maxScrollX)
        }
        needsDisplay = true
    }
}
