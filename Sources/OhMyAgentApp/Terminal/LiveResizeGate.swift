// @author ixxxxoooo
// 实时缩放门控:窗口缩放 / 拖分栏期间终端尺寸每帧都在变,而 SwiftTerm 每次尺寸变化都会重排整段回滚(默认 5000 行)
// 并给 pty 发 SIGWINCH,代价与回滚长度成正比。门控期间终端保持原尺寸(列数不变,由外层 SwiftUI 裁剪),
// 拖动/缩放结束(或尺寸停稳 ~100ms)时一次性应用最新尺寸。纯逻辑,便于测试。

import Foundation

/// 终端尺寸应用的门控状态机。
struct LiveResizeGate {
    /// 门控期间无新尺寸到达多久后自动应用(兜底:拖动结束的通知丢失、或用户在拖动中停住时也能收敛)。
    static let settleDelay: Duration = .milliseconds(100)

    /// 门控期间暂存的最新目标尺寸(nil 表示没有待应用的尺寸)。
    private(set) var pending: NSSize?

    /// 提交一个新尺寸。
    /// - Parameters:
    ///   - size: SwiftUI/AppKit 给出的新尺寸(调用方已过滤退化尺寸)
    ///   - gated: 当前是否处于实时缩放/拖动中
    ///   - current: 终端当前实际生效的尺寸
    /// - Returns: 需要立即应用的尺寸;门控中返回 nil(已暂存)
    mutating func submit(_ size: NSSize, gated: Bool, current: NSSize) -> NSSize? {
        guard gated else {
            pending = nil
            return size
        }
        pending = size == current ? nil : size
        return nil
    }

    /// 取出待应用的尺寸(拖动/缩放结束或停稳时调用)。
    /// - Parameter current: 终端当前实际生效的尺寸
    /// - Returns: 需要应用的尺寸;没有或与当前相同返回 nil
    mutating func flush(current: NSSize) -> NSSize? {
        defer { pending = nil }
        guard let pending, pending != current else { return nil }
        return pending
    }
}
