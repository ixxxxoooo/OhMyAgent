// @author ixxxxoooo
// 权限模式的色调:每种模式在输入区有不同的强调色(参考 Cursor:越「放权」越醒目)。
// 只描述语义色调,具体颜色由界面层映射,便于单测覆盖全部模式 ID。

import Foundation

/// 模式色调。
public enum ModeTone: String, CaseIterable, Sendable {
    /// 中性灰:仅用于无法归类的占位(未知模式不再回退到它,而是稳定映射到彩色色调)
    case neutral
    /// 主题强调色:手动确认 / 默认模式(Claude Code `default`、OpenCode `build` 等)
    case accent
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
        "default": .accent,
        "acceptEdits": .green,
        "plan": .blue,
        "auto": .purple,
        "dontAsk": .amber,
        "bypassPermissions": .red,
        // OpenCode 与其他 Agent 常见的模式 ID
        "build": .accent,
        "ask": .accent,
        "manual": .accent,
        "code": .accent,
        "architect": .blue,
        "explore": .purple,
        "general": .green,
        "autoEdit": .green,
        "auto-edit": .green,
        "yolo": .red,
        "bypass": .red,
    ]

    /// 未知模式可映射到的彩色色调(不含红色:红色只留给明确的「危险」模式)。
    private static let fallbackTones: [ModeTone] = [.accent, .green, .blue, .purple, .amber]

    /// 取模式的色调。
    /// - Parameter modeId: ACP 模式 ID(如 `acceptEdits`)
    /// - Returns: 已知模式返回登记的色调;未知模式按 ID 稳定映射到彩色色调(同一 ID 永远同色),不再是灰色
    public static func tone(forMode modeId: String) -> ModeTone {
        if let known = knownModes[modeId] { return known }
        guard !modeId.isEmpty else { return .accent }
        // djb2:Swift 的 hashValue 每次启动不同,这里需要跨启动稳定
        var hash: UInt64 = 5381
        for byte in modeId.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return fallbackTones[Int(hash % UInt64(fallbackTones.count))]
    }
}
