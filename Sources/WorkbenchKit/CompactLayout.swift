// @author ixxxxoooo
// 最小模式:窗口窄于阈值时自动收起项目栏与工具栏(对照 Cursor),拉宽后恢复。
// 只恢复「被自动收起」的面板;用户手动收起的不会被自动展开。

import Foundation

/// 窗口过窄时的自动收起策略(纯逻辑,无视图)。
public struct CompactLayout: Equatable, Sendable {
    /// 进入最小模式的窗口宽度阈值(低于此值收起侧栏)。
    public static let threshold: Double = 780
    /// 退出最小模式的宽度(带回差,避免在阈值附近来回抖动)。
    public static let exitWidth: Double = 820

    /// 当前是否处于最小模式。
    public private(set) var isCompact = false
    /// 项目栏是否由最小模式自动收起。
    private var autoCollapsedSidebar = false
    /// 工具栏是否由最小模式自动收起。
    private var autoCollapsedTools = false

    public init() {}

    /// 按窗口宽度更新模式,并据此调整布局中的面板显隐。
    /// - Parameters:
    ///   - width: 当前窗口内容宽度;非正数或非有限值忽略。
    ///   - layout: 工作台布局(原地修改)。
    public mutating func update(width: Double, layout: inout WorkbenchLayout) {
        guard width.isFinite, width > 0 else { return }
        if !isCompact, width < Self.threshold {
            isCompact = true
            if layout.leftVisible { layout.leftVisible = false; autoCollapsedSidebar = true }
            if layout.rightVisible { layout.rightVisible = false; autoCollapsedTools = true }
        } else if isCompact, width >= Self.exitWidth {
            isCompact = false
            // 用户在最小模式中手动打开过的面板保持原样,只恢复仍处于收起状态的
            if autoCollapsedSidebar, !layout.leftVisible { layout.leftVisible = true }
            if autoCollapsedTools, !layout.rightVisible { layout.rightVisible = true }
            autoCollapsedSidebar = false
            autoCollapsedTools = false
        }
    }
}
