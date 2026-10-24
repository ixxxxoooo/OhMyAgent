// @author ixxxxoooo
// 编辑器的 IDE 外围视图:右侧缩略图(minimap)与顶部粘性滚动(sticky scroll)。
// 两者都只读取编辑器的行索引、文本与滚动位置,不改动文本布局。

import AppKit
import DesignSystem

/// 要显示哪些 IDE 外围视图。
public struct EditorChrome: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 右侧缩略图
    public static let minimap = EditorChrome(rawValue: 1 << 0)
    /// 顶部粘性滚动
    public static let stickyScroll = EditorChrome(rawValue: 1 << 1)
    /// 行号栏折叠箭头与代码折叠
    public static let folding = EditorChrome(rawValue: 1 << 2)
    /// 右侧概览尺(诊断、查找命中、Git 改动的缩略标记)
    public static let overviewRuler = EditorChrome(rawValue: 1 << 3)
}

/// 偏好键(设置 → 编辑器 → 代码编辑)。
public extension EditorBehaviorPrefs {
    /// 缩略图开关的键
    static let minimapKey = "editor.minimap"
    /// 粘性滚动开关的键
    static let stickyScrollKey = "editor.stickyScroll"
    /// 幽灵补全(Tab 接受 AI 续写)开关的键
    static let ghostCompletionKey = "editor.ghostCompletion"
    /// 是否启用幽灵补全(默认关:每次停顿都会向模型发请求)。
    static var ghostCompletion: Bool { UserDefaults.standard.object(forKey: ghostCompletionKey) as? Bool ?? false }
    /// 是否显示缩略图(默认开)。
    static var minimap: Bool { UserDefaults.standard.object(forKey: minimapKey) as? Bool ?? true }
    /// 是否显示粘性滚动(默认开)。
    static var stickyScroll: Bool { UserDefaults.standard.object(forKey: stickyScrollKey) as? Bool ?? true }
}
