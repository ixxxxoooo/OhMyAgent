// @author ixxxxoooo
// 对话锚点的纯逻辑(无视图,便于测试):提问文本拆分、刻度的 Dock 式阶梯放大、超量抽样、预览卡片贴边策略。

import ChatKit
import Foundation
import SwiftUI

/// 一个对话锚点(对应一条用户提问)。
struct ConversationAnchor: Identifiable, Equatable {
    let id: UUID
    /// 在时间线条目数组里的下标
    let index: Int
    /// 第几条提问(从 1 起)
    let number: Int
    /// 提问首行(截断)
    let title: String
    /// 首行之后的内容缩略(无则为空):区分标题相同的多次提问
    let body: String
}

/// 提问文本拆分。
enum AnchorText {
    /// 首行标题最大字符数
    static let maxTitle = 80
    /// 正文缩略最大字符数
    static let maxBody = 200
    /// 参与拆分的原文前缀长度(超长提问不整段扫描)
    private static let scanLimit = 600

    /// 把提问拆成「首行标题 + 后续缩略」。
    /// - Parameter text: 提问显示文本
    /// - Returns: 标题与正文;全空时两者都是空字符串
    static func split(_ text: String) -> (title: String, body: String) {
        let lines = text.prefix(scanLimit)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return ("", "") }
        let body = lines.dropFirst().joined(separator: "\n")
        return (String(first.prefix(maxTitle)), String(body.prefix(maxBody)))
    }
}

/// 刻度条几何:Dock 式阶梯放大与抽样。
enum AnchorRailMetrics {
    /// 单根刻度占用的行高(含命中区,行与行紧挨,无死区)
    static let rowHeight: CGFloat = 17

    /// 一根刻度的外观。
    struct Indicator: Equatable {
        let width: CGFloat
        let height: CGFloat
        let opacity: Double
    }

    /// 按与悬停项的距离(或当前项状态)计算刻度外观:越近越长越实,像 Dock 一样随光标起伏。
    /// - Parameters:
    ///   - distance: 与悬停项的间隔数;没有悬停时为 nil
    ///   - isCurrent: 是否为当前所在提问
    /// - Returns: 宽、高与不透明度
    static func indicator(distance: Int?, isCurrent: Bool) -> Indicator {
        guard let distance else {
            return isCurrent ? Indicator(width: 18, height: 2, opacity: 0.9) : Indicator(width: 8, height: 1.5, opacity: 0.35)
        }
        switch distance {
        case ..<1: return Indicator(width: 26, height: 2, opacity: 1)
        case 1: return Indicator(width: 18, height: 1.5, opacity: 0.6)
        case 2: return Indicator(width: 13, height: 1.5, opacity: 0.45)
        default: return Indicator(width: 8, height: 1.5, opacity: isCurrent ? 0.9 : 0.3)
        }
    }

    /// 提问数超过可容纳行数时按步长抽样,始终保留当前项。
    /// - Parameters:
    ///   - anchors: 全部锚点
    ///   - current: 当前锚点 id
    ///   - available: 可用高度
    /// - Returns: 要显示的锚点(保持原顺序)
    static func sample(_ anchors: [ConversationAnchor], current: UUID?, available: CGFloat) -> [ConversationAnchor] {
        let capacity = max(2, Int(max(available, 0) / rowHeight))
        guard anchors.count > capacity else { return anchors }
        let stride = max(1, Int((Double(anchors.count) / Double(capacity)).rounded(.up)))
        return anchors.enumerated().filter { $0.offset % stride == 0 || $0.element.id == current }.map(\.element)
    }

    /// 预览卡片相对刻度的对齐:首项贴顶、末项贴底、其余垂直居中,避免卡片越出刻度条上下。
    /// - Parameters:
    ///   - index: 刻度在显示列表里的下标
    ///   - count: 显示的刻度总数
    /// - Returns: 叠层对齐方式
    static func popoverAlignment(index: Int, count: Int) -> Alignment {
        if index <= 0 { return .topLeading }
        if index >= count - 1 { return .bottomLeading }
        return .leading
    }
}
