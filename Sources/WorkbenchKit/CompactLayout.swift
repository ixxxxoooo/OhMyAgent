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

    /// 窗口宽度档位:拖动窗口时宽度每帧都变,但档位只在跨越阈值时才变,
    /// 视图只观察档位即可避免每帧触发布局状态失效。
    public enum Bucket: Equatable, Sendable {
        /// 低于进入阈值。
        case compact
        /// 回差区间(阈值 ≤ 宽度 < 退出宽度):不改变当前模式。
        case hysteresis
        /// 不低于退出宽度。
        case regular
        /// 宽度非法(非正数/非有限值),忽略。
        case invalid

        /// 该档位的代表宽度,用于喂给 `update(width:layout:)`;非法档位返回 nil。
        public var representativeWidth: Double? {
            switch self {
            case .compact: CompactLayout.threshold - 1
            case .hysteresis: CompactLayout.threshold
            case .regular: CompactLayout.exitWidth
            case .invalid: nil
            }
        }
    }

    /// 把窗口宽度归入档位。
    /// - Parameter width: 窗口内容宽度。
    /// - Returns: 对应档位;非正数或非有限值返回 `.invalid`。
    public static func bucket(for width: Double) -> Bucket {
        guard width.isFinite, width > 0 else { return .invalid }
        if width < threshold { return .compact }
        if width < exitWidth { return .hysteresis }
        return .regular
    }

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
