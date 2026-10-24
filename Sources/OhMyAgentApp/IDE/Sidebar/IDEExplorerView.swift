// @author ixxxxoooo
// IDE 资源管理器的 AppKit 表格:`NSTableView` 固定 22pt 行高,系统只创建可见行(数万行也不卡)。
// 数据来自每窗口的 `ExplorerTree.rows`(已展平),本视图只负责绘制、选择、键盘、拖放与回调。
// 右键菜单由外层 SwiftUI 的 `omContextMenu` 提供(见 `IDEExplorerPane`),这里只暴露「点击所在行」。

import AppKit
import DesignSystem
import GitKit
import IconKit
import SwiftUI
import WorkbenchKit

/// 资源管理器行高(与规范的紧凑列表一致)。
enum IDEExplorerMetrics {
    static let rowHeight: CGFloat = 22
    static let indent: CGFloat = 12
    static let leading: CGFloat = 8
}

// MARK: - 行与单元格

/// 行视图:选中/悬停底色取主题令牌,圆角取 `OMRadius.tag`。
final class IDEExplorerRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    // 悬停由表格按鼠标位置统一计算(见 `IDEExplorerTable.refreshHover`):
    // 行视图会被复用,靠行内的进入/离开事件会在滚动、快速移动时漏掉「离开」,留下一整片残留的悬停底色。

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        NSColor(OMColors.hoverFill).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(OMColors.selectedFill).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: OMRadius.tag, yRadius: OMRadius.tag).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// 单元格:展开箭头 + 彩色文件图标 + 名称 + 右侧 Git 字母徽标,手动布局(无 Auto Layout)。
final class IDEExplorerCell: NSView {
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var depth = 0
    private var showsChevron = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [chevron, icon] { view.imageScaling = .scaleNone; addSubview(view) }
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.usesSingleLineMode = true
        badge.alignment = .right
        addSubview(name)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { nil }

    /// 填充一行内容。
    func configure(_ row: ExplorerRowItem, decoration: GitDecorationKind?, isActive: Bool) {
        depth = row.depth
        showsChevron = row.entry.isDirectory
        let scale = OMScale.ui
        chevron.isHidden = !row.entry.isDirectory
        if row.entry.isDirectory {
            chevron.image = OMIconRenderer.nsImage(row.isExpanded ? "chevron-down" : "chevron-right", size: 12)
            chevron.contentTintColor = NSColor(OMColors.tertiaryText)
        }
        icon.image = OMFileIconCatalog.nsImage(name: row.entry.name, isDirectory: row.entry.isDirectory, expanded: row.isExpanded, size: 16)
        name.font = NSFont.systemFont(ofSize: 13 * scale)
        name.stringValue = row.entry.name
        let tint = decoration.map(Self.tint)
        name.textColor = tint.map(NSColor.init) ?? NSColor(isActive ? OMColors.primaryText : OMColors.primaryText)
        badge.font = NSFont.systemFont(ofSize: 11 * scale, weight: .medium)
        badge.stringValue = decoration?.letter ?? ""
        badge.textColor = tint.map(NSColor.init) ?? NSColor(OMColors.tertiaryText)
        needsLayout = true
    }

    private static func tint(_ kind: GitDecorationKind) -> Color {
        switch kind {
        case .modified: return OMColors.warning
        case .added, .renamed, .untracked: return OMColors.success
        case .deleted, .conflict: return OMColors.danger
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = IDEExplorerMetrics.leading + CGFloat(depth) * IDEExplorerMetrics.indent
        chevron.frame = NSRect(x: x, y: (h - 12) / 2, width: 12, height: 12)
        x += 16
        icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        x += 22
        let badgeWidth: CGFloat = badge.stringValue.isEmpty ? 0 : 18
        badge.frame = NSRect(x: bounds.width - badgeWidth - 10, y: (h - 14) / 2, width: badgeWidth, height: 14)
        let nameHeight = name.intrinsicContentSize.height
        name.frame = NSRect(x: x, y: (h - nameHeight) / 2, width: max(0, bounds.width - x - badgeWidth - 14), height: nameHeight)
    }
}

// MARK: - 表格

/// 表格:增加键盘处理回调与「不抢焦点」的行为。
final class IDEExplorerTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    private var hoverTracking: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    /// 当前鼠标所在的行(没有为 -1)。
    private(set) var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        // 滚动时鼠标没动但所在行变了:重新计算
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHover() }
        }
    }

    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover(forceNone: true) }

    /// 按当前鼠标位置重算悬停行,只让该行的行视图显示悬停底色。
    /// - Parameter forceNone: 鼠标已离开表格时为 true
    func refreshHover(forceNone: Bool = false) {
        var target = -1
        if !forceNone, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { target = row(at: point) }
        }
        hoveredRow = target
        enumerateAvailableRowViews { view, row in (view as? IDEExplorerRowView)?.isHovered = row == target }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - 桥接

/// 资源管理器表格(NSViewRepresentable)。
struct IDEExplorerView: NSViewRepresentable {
    let workspace: IDEWorkspace
    let rows: [ExplorerRowItem]
    let decorations: GitDecorationIndex
    let activePath: String?
    /// 刷新主题/字号用的版本号(变化即整表重载)
    let styleRevision: Int
    /// 右键所在行(由 Coordinator 在鼠标右键时写入,供外层菜单求值)
    let hitBox: IDEExplorerHitBox

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, hitBox: hitBox) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = IDEExplorerTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = IDEExplorerMetrics.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked)
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onKey = { [weak coordinator = context.coordinator] event in coordinator?.handleKey(event) ?? false }
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, decorations: decorations, activePath: activePath, styleRevision: styleRevision)
    }

    /// 右键命中盒:Coordinator 写入,外层 `omContextMenu` 读取。
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let workspace: IDEWorkspace
        let hitBox: IDEExplorerHitBox
        weak var table: IDEExplorerTable?
        private var rows: [ExplorerRowItem] = []
        private var decorations = GitDecorationIndex()
        private var activePath: String?
        private var styleRevision = -1
        private var syncing = false
        private var lastActive: String?

        init(workspace: IDEWorkspace, hitBox: IDEExplorerHitBox) {
            self.workspace = workspace
            self.hitBox = hitBox
            super.init()
            hitBox.rowAt = { [weak self] point in self?.row(atWindowPoint: point) }
        }

        /// 窗口坐标 → 行条目。
        private func row(atWindowPoint point: NSPoint) -> ExplorerRowItem? {
            guard let table else { return nil }
            let index = table.row(at: table.convert(point, from: nil))
            if index >= 0, index < rows.count {
                // 右键点中未选中的行:先单选该行,与 Finder/Cursor 一致
                if !table.selectedRowIndexes.contains(index) { table.selectRowIndexes([index], byExtendingSelection: false) }
                return rows[index]
            }
            return nil
        }

        /// SwiftUI 数据变化后同步到表格。
        func update(rows newRows: [ExplorerRowItem], decorations newDecorations: GitDecorationIndex, activePath newActive: String?, styleRevision newStyle: Int) {
            guard let table else { return }
            let rowsChanged = newRows != rows
            let decorationsChanged = newDecorations != decorations
            let styleChanged = newStyle != styleRevision
            let selected = selectedPaths()
            rows = newRows
            decorations = newDecorations
            activePath = newActive
            styleRevision = newStyle
            if rowsChanged || decorationsChanged || styleChanged {
                syncing = true
                table.reloadData()
                restoreSelection(selected)
                syncing = false
            }
            // 当前编辑器文件变化:自动定位(只在变化时,避免打断用户的选择)
            if newActive != lastActive {
                lastActive = newActive
                if let newActive, workspace.revealPath == nil { select(path: newActive, scroll: true) }
            }
            // 目标行尚未列举出来时保留请求,等下一次行数据到达再定位
            if let reveal = workspace.revealPath, rows.contains(where: { $0.entry.path == reveal }) {
                workspace.revealPath = nil
                select(path: reveal, scroll: true)
            }
        }

        private func selectedPaths() -> [String] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].entry.path : nil }
        }

        private func restoreSelection(_ paths: [String]) {
            guard let table else { return }
            let set = Set(paths)
            let indexes = IndexSet(rows.indices.filter { set.contains(rows[$0].entry.path) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        private func select(path: String, scroll: Bool) {
            guard let table, let index = rows.firstIndex(where: { $0.entry.path == path }) else { return }
            syncing = true
            table.selectRowIndexes([index], byExtendingSelection: false)
            syncing = false
            workspace.selection = [path]
            if scroll { table.scrollRowToVisible(index) }
        }

        // MARK: 数据源

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("row")
            let view = (tableView.makeView(withIdentifier: id, owner: nil) as? IDEExplorerRowView) ?? IDEExplorerRowView()
            view.identifier = id
            view.isHovered = row == (tableView as? IDEExplorerTable)?.hoveredRow
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? IDEExplorerCell) ?? IDEExplorerCell()
            cell.identifier = id
            let item = rows[row]
            cell.configure(item, decoration: decorations.kind(for: item.entry.path), isActive: item.entry.path == activePath)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            workspace.selection = selectedPaths()
        }

        // MARK: 点击

        @objc func clicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            guard flags.intersection([.command, .shift]).isEmpty else { return }
            let item = rows[table.clickedRow]
            if item.entry.isDirectory {
                if NSApp.currentEvent?.clickCount == 1 { workspace.tree.toggle(item.entry.path) }
            } else {
                workspace.open(item.entry.path, preview: true, beside: flags.contains(.option))
            }
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let item = rows[table.clickedRow]
            if !item.entry.isDirectory { workspace.open(item.entry.path, preview: false) }
        }

        // MARK: 键盘

        /// 处理按键:→/← 展开折叠、↩ 重命名、⌘↓/空格 打开、⌘⌫ 删除。
        func handleKey(_ event: NSEvent) -> Bool {
            guard let table else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let index = table.selectedRow
            guard index >= 0, index < rows.count else { return false }
            let item = rows[index]
            switch (event.keyCode, flags) {
            case (124, []):   // →
                if item.entry.isDirectory, !item.isExpanded { workspace.tree.expand(item.entry.path); return true }
                if item.entry.isDirectory, index + 1 < rows.count { table.selectRowIndexes([index + 1], byExtendingSelection: false); return true }
                return false
            case (123, []):   // ←
                if item.entry.isDirectory, item.isExpanded { workspace.tree.collapse(item.entry.path); return true }
                let parent = (item.entry.path as NSString).deletingLastPathComponent
                if let parentIndex = rows.firstIndex(where: { $0.entry.path == parent }) {
                    table.selectRowIndexes([parentIndex], byExtendingSelection: false)
                    table.scrollRowToVisible(parentIndex)
                    return true
                }
                return false
            case (36, []), (76, []):   // ↩
                workspace.rename(item.entry.path)
                return true
            case (125, [.command]), (49, []):   // ⌘↓ / 空格
                if item.entry.isDirectory { workspace.tree.toggle(item.entry.path) } else { workspace.open(item.entry.path, preview: false) }
                return true
            case (51, [.command]):   // ⌘⌫
                workspace.trash(selectedPaths())
                return true
            case (6, [.command]):   // ⌘Z
                if workspace.canUndo { workspace.undo(); return true }
                return false
            default:
                return false
            }
        }

        // MARK: 拖放

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count else { return nil }
            return URL(fileURLWithPath: rows[row].entry.path) as NSURL
        }

        /// 落点目录:落在目录行上取该目录;落在文件行上取其父目录;空白处取根目录。
        private func dropDirectory(row: Int) -> String? {
            if row >= 0, row < rows.count {
                let item = rows[row]
                return item.entry.isDirectory ? item.entry.path : (item.entry.path as NSString).deletingLastPathComponent
            }
            return workspace.root
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let directory = dropDirectory(row: dropOperation == .on ? row : -1) else { return [] }
            // 统一把落点改成「在某行之上」或整表(根目录)
            if dropOperation == .above { tableView.setDropRow(-1, dropOperation: .on) }
            else if let index = rows.firstIndex(where: { $0.entry.path == directory }), index != row { tableView.setDropRow(index, dropOperation: .on) }
            else if directory == workspace.root { tableView.setDropRow(-1, dropOperation: .on) }
            let local = (info.draggingSource as? NSTableView) === tableView
            return local ? .move : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let directory = dropDirectory(row: row) else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let sources = urls.map(\.path)
            guard !sources.isEmpty else { return false }
            workspace.performDrop(sources: sources, into: directory)
            return true
        }
    }
}

/// 右键命中盒:表格把「窗口坐标 → 行」的查询函数放进来,外层菜单在右键时调用。
@MainActor
final class IDEExplorerHitBox {
    var rowAt: ((NSPoint) -> ExplorerRowItem?)?
}
