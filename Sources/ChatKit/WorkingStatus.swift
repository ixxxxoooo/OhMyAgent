// @author ygw
// 运行中的等待文案:对齐 Claude Code 的「✻ Cogitating… (12s · esc to interrupt)」。
// 纯逻辑(无视图),便于测试:动词表、按轮次稳定挑选、耗时格式化与整行文案。

import Foundation

/// 等待状态文案的生成器。
public enum WorkingStatus {
    /// 动词表(中文原文,同时是本地化键;与 Claude Code 的趣味动词同风格)。
    public static let verbs: [String] = [
        "思考中", "琢磨中", "推敲中", "构思中", "斟酌中", "酝酿中", "梳理中", "盘算中",
    ]

    /// 动画字符帧(与 Claude Code 终端动画一致:· ✢ ✳ ✶ ✻ ✽ 往返)。
    public static let glyphFrames: [String] = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    /// 按轮次稳定挑选动词:同一轮内不变(避免文字乱跳),不同轮次轮换。
    /// - Parameter seed: 轮次种子(如开始时间的秒级时间戳)
    /// - Returns: 本地化后的动词
    public static func verb(seed: Int) -> String {
        guard !verbs.isEmpty else { return "" }
        let index = ((seed % verbs.count) + verbs.count) % verbs.count
        return ChatL10n.t(verbs[index])
    }

    /// 取动画帧。
    /// - Parameter tick: 递增的帧计数
    public static func glyph(tick: Int) -> String {
        guard !glyphFrames.isEmpty else { return "" }
        return glyphFrames[((tick % glyphFrames.count) + glyphFrames.count) % glyphFrames.count]
    }

    /// 耗时格式化:`12s` / `1m 05s` / `1h 02m`。
    /// - Parameter seconds: 已运行秒数(负数按 0 处理)
    public static func elapsed(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value < 60 { return "\(value)s" }
        if value < 3600 { return String(format: "%dm %02ds", value / 60, value % 60) }
        return String(format: "%dh %02dm", value / 3600, (value % 3600) / 60)
    }

    /// 整行文案,例如 `思考中… (12s · 按 Esc 中断)`。
    /// - Parameters:
    ///   - verb: 动词
    ///   - seconds: 已运行秒数
    ///   - canInterrupt: 是否提示 Esc 中断
    public static func line(verb: String, seconds: Int, canInterrupt: Bool) -> String {
        var parts = [elapsed(seconds)]
        if canInterrupt { parts.append(ChatL10n.t("按 Esc 中断")) }
        return "\(verb)… (\(parts.joined(separator: " · ")))"
    }
}
