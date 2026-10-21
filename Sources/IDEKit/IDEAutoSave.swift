// @author ixxxxoooo
// IDE 自动保存策略(无视图):关闭 / 停止输入后延迟保存 / 窗口失去焦点时保存。设置页写入同名键。

import Foundation

public enum IDEAutoSaveMode: String, CaseIterable, Sendable {
    /// 关闭(只在 ⌘S 时保存)
    case off
    /// 最后一次修改后停顿一秒自动保存
    case afterDelay
    /// 窗口失去键盘焦点时保存全部
    case onFocusLoss

    /// UserDefaults 键
    public static let key = "ide.autoSave"
    /// 延迟保存的停顿时长
    public static let delay: Duration = .seconds(1)

    /// 当前设置(缺省或非法值回退为关闭)。
    public static var current: IDEAutoSaveMode {
        UserDefaults.standard.string(forKey: key).flatMap(IDEAutoSaveMode.init(rawValue:)) ?? .off
    }
}
