// @author ixxxxoooo
// 平滑滚轮的纯数学模型:把鼠标滚轮「一格一跳」的离散位移,按指数衰减拆成逐帧的小位移。
// 与帧率无关(用真实 dt 计算),不依赖 AppKit,便于单测。

import Foundation

/// 平滑档位:数值越大,滚动越「飘」。
enum SmoothWheelLevel: String, CaseIterable, Identifiable {
    case light, standard, soft

    var id: String { rawValue }

    /// 设置页显示名
    var title: String {
        switch self {
        case .light: "轻快"
        case .standard: "标准"
        case .soft: "柔和"
        }
    }

    /// 衰减时间常数(秒):剩余位移每过 tau 秒衰减到约 37%
    var tau: Double {
        switch self {
        case .light: 0.07
        case .standard: 0.11
        case .soft: 0.17
        }
    }

    /// 解析偏好值,无法识别时回退轻快档(默认档)。
    /// - Parameter raw: 存储的字符串
    /// - Returns: 档位
    static func resolve(_ raw: String) -> SmoothWheelLevel { SmoothWheelLevel(rawValue: raw) ?? .light }
}

/// 逐帧位移模型:累计「待滚动」的剩余位移,每帧按指数衰减吐出整数像素。
struct SmoothWheelModel {
    /// 每一格滚轮对应的像素(滚轮行数 × 此值)
    static let pixelsPerLine: Double = 36
    /// 待滚动的剩余位移上限(像素),防止狂拨滚轮后滚过头
    static let maxRemaining: Double = 6_000
    /// 小于该位移视为已到位,直接吐完
    static let epsilon: Double = 0.5

    /// 横纵向剩余位移
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    /// 小数像素累计(逐帧取整后的余数)
    private var carryX = 0.0
    private var carryY = 0.0

    /// 是否还有待滚动的位移。
    var isActive: Bool { abs(remainingX) >= Self.epsilon || abs(remainingY) >= Self.epsilon }

    /// 追加一次滚轮位移;与剩余位移方向相反时丢弃旧的剩余(立刻反向,不拖泥带水)。
    /// - Parameters:
    ///   - dx: 横向位移(像素)
    ///   - dy: 纵向位移(像素)
    mutating func add(dx: Double, dy: Double) {
        remainingX = Self.accumulate(remainingX, dx)
        remainingY = Self.accumulate(remainingY, dy)
    }

    /// 推进一帧。
    /// - Parameters:
    ///   - dt: 距上一帧的时间(秒);非正数视为 0
    ///   - tau: 衰减时间常数(秒);非正数时一次吐完
    /// - Returns: 本帧应滚动的整数像素 (x, y)
    mutating func advance(dt: Double, tau: Double) -> (x: Int, y: Int) {
        let fraction = tau > 0 ? 1 - exp(-max(dt, 0) / tau) : 1
        let stepX = Self.take(&remainingX, &carryX, fraction)
        let stepY = Self.take(&remainingY, &carryY, fraction)
        return (stepX, stepY)
    }

    /// 清空所有状态(点击、切换窗口、关闭功能时)。
    mutating func reset() {
        remainingX = 0; remainingY = 0; carryX = 0; carryY = 0
    }

    private static func accumulate(_ remaining: Double, _ delta: Double) -> Double {
        guard delta != 0 else { return remaining }
        let base = (remaining != 0 && (remaining > 0) != (delta > 0)) ? 0 : remaining
        return min(max(base + delta, -maxRemaining), maxRemaining)
    }

    /// 从剩余位移里取出本帧份额,并把小数部分留到下一帧。
    private static func take(_ remaining: inout Double, _ carry: inout Double, _ fraction: Double) -> Int {
        guard remaining != 0 else { return 0 }
        var part = abs(remaining) < epsilon * 2 ? remaining : remaining * fraction
        remaining -= part
        if abs(remaining) < epsilon { part += remaining; remaining = 0 }
        let total = part + carry
        // 到位的最后一帧四舍五入吐完,保证累计像素恰好等于输入;中途帧取整并把余数留给下一帧
        let whole = remaining == 0 ? total.rounded() : total.rounded(.towardZero)
        carry = remaining == 0 ? 0 : total - whole
        return Int(whole)
    }
}
