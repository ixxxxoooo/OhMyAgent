// @author ixxxxoooo
// Spinner Verbs(等待动词)风格:运行中等待文案的多套风格,在「设置 → 外观」里切换。
// 纯逻辑(无视图),便于测试;动词以中文原文作键,英文由 `Localizable.strings` 提供。

import Foundation

/// 等待动词风格。
public enum WorkingVerbStyle: String, CaseIterable, Identifiable, Sendable {
    /// 经典:稳重简洁(默认)
    case classic
    /// 趣味:轻松幽默的俏皮话
    case playful
    /// Claude Code 风:对齐官方终端里的 Cogitating / Pondering 一类动词
    case claudeCode
    /// 诗意:书卷气
    case poetic
    /// 极客:工程师黑话
    case geek
    /// 极简:统一为「工作中」
    case minimal

    public var id: String { rawValue }

    /// 风格名称(中文原文,同时是本地化键)。
    public var title: String {
        switch self {
        case .classic: "经典"
        case .playful: "趣味"
        case .claudeCode: "Claude Code"
        case .poetic: "诗意"
        case .geek: "极客"
        case .minimal: "极简"
        }
    }

    /// 风格说明(中文原文,同时是本地化键)。
    public var summary: String {
        switch self {
        case .classic: "思考中、琢磨中、推敲中…"
        case .playful: "摸鱼中、炼丹中、薅头发中…"
        case .claudeCode: "沉思中、踱步中、冥想中…"
        case .poetic: "凝神中、遐思中、斟字酌句中…"
        case .geek: "编译宇宙中、梳理依赖中、调优中…"
        case .minimal: "工作中"
        }
    }

    /// 动词表(中文原文,同时是本地化键)。
    public var verbs: [String] {
        switch self {
        case .classic: ["思考中", "琢磨中", "推敲中", "构思中", "斟酌中", "酝酿中", "梳理中", "盘算中"]
        case .playful: ["摸鱼中", "炼丹中", "薅头发中", "掐指一算中", "憋大招中", "搬砖中", "喂猫中", "冲咖啡中"]
        case .claudeCode: ["沉思中", "踱步中", "冥想中", "酿造中", "蹦跶中", "琢磨透中", "神游中", "凝思中"]
        case .poetic: ["凝神中", "遐思中", "斟字酌句中", "静待花开中", "拾掇思绪中", "望月沉吟中", "研墨中", "听风中"]
        case .geek: ["编译宇宙中", "梳理依赖中", "调优中", "遍历语法树中", "回收内存中", "预热缓存中", "握手中", "解析意图中"]
        case .minimal: ["工作中"]
        }
    }

    /// 动画字符帧。
    public var glyphFrames: [String] {
        switch self {
        case .classic, .playful, .claudeCode: ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
        case .poetic: ["◜", "◠", "◝", "◞", "◡", "◟"]
        case .geek: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        case .minimal: ["●", "◉", "○", "◉"]
        }
    }

    /// 静止(减弱动态效果或等待用户)时显示的字符。
    public var restingGlyph: String {
        switch self {
        case .classic, .playful, .claudeCode: "✻"
        case .poetic: "◠"
        case .geek: "⠿"
        case .minimal: "●"
        }
    }

    /// 解析存储值,无法识别时回退为经典。
    /// - Parameter raw: 存储的原始字符串
    public static func resolve(_ raw: String?) -> WorkingVerbStyle {
        raw.flatMap(WorkingVerbStyle.init(rawValue:)) ?? .classic
    }

    /// 从偏好读取当前风格。
    /// - Parameter defaults: 偏好存储
    public static func current(_ defaults: UserDefaults = .standard) -> WorkingVerbStyle {
        resolve(defaults.string(forKey: ClientPrefs.Key.workingVerbStyle))
    }
}
