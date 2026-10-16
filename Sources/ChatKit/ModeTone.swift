// @author ixxxxoooo
// 权限模式的色调:每种模式在输入区有不同的强调色(参考 Cursor:越「放权」越醒目)。
// 只描述语义色调,具体颜色由界面层映射,便于单测覆盖全部模式 ID。

import Foundation

/// 模式色调。
public enum ModeTone: String, CaseIterable, Sendable {
    /// 中性灰:手动确认(默认)
    case neutral
    /// 绿:自动接受编辑
    case green
    /// 蓝:计划模式(只读规划)
    case blue
    /// 紫:自动模式(分类器代审)
    case purple
    /// 琥珀:不再询问(拒绝未预先批准的操作)
    case amber
    /// 红:跳过全部权限(危险)
    case red

    /// 已知的 Claude Code 模式 ID → 色调。
    public static let knownModes: [String: ModeTone] = [
        "default": .neutral,
        "acceptEdits": .green,
        "plan": .blue,
        "auto": .purple,
        "dontAsk": .amber,
        "bypassPermissions": .red,
    ]

    /// 取模式的色调。
    /// - Parameter modeId: ACP 模式 ID(如 `acceptEdits`)
    /// - Returns: 对应色调;未知模式返回中性
    public static func tone(forMode modeId: String) -> ModeTone { knownModes[modeId] ?? .neutral }
}
