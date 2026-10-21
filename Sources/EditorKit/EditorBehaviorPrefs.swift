// @author ixxxxoooo
// 编辑器行为偏好(设置 → 编辑器 → 代码编辑):自动闭合、当前行高亮、括号匹配。读取走 UserDefaults,设置页用同名键的 @AppStorage 写入。

import Foundation

public enum EditorBehaviorPrefs {
    /// 自动闭合括号与引号的键
    public static let autoCloseKey = "editor.autoClose"
    /// 当前行高亮的键
    public static let currentLineKey = "editor.currentLine"
    /// 括号匹配高亮的键
    public static let bracketMatchKey = "editor.bracketMatch"

    /// 是否自动闭合括号与引号(默认开)。
    public static var autoClose: Bool { value(autoCloseKey) }
    /// 是否高亮当前行(默认开)。
    public static var currentLine: Bool { value(currentLineKey) }
    /// 是否高亮配对括号(默认开)。
    public static var bracketMatch: Bool { value(bracketMatchKey) }

    private static func value(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
