// @author ixxxxoooo
// 帧内合并:同一个主循环回合里被多次请求的动作只执行一次(最后一次请求的闭包),
// 用于把「内容高度变化」「时间线修订号变化」等多个触发源引起的 scrollTo 合并成每帧至多一次。

import Foundation

/// 同一主循环回合内多次 `schedule` 只执行一次。
@MainActor
public final class FrameCoalescedAction {
    private var pending: (@MainActor () -> Void)?
    /// 实际执行次数(测试与诊断用)
    public private(set) var executions = 0
    /// 被合并掉(没有单独执行)的请求次数(测试与诊断用)
    public private(set) var coalesced = 0

    public init() {}

    /// 请求在本回合结束时执行 `action`;本回合内已有待执行请求时,用新的闭包替换它(不会执行两次)。
    /// - Parameter action: 要执行的动作
    public func schedule(_ action: @escaping @MainActor () -> Void) {
        if pending != nil { coalesced += 1 }
        let needsDispatch = pending == nil
        pending = action
        guard needsDispatch else { return }
        Task { @MainActor [weak self] in
            guard let self, let action = self.pending else { return }
            self.pending = nil
            self.executions += 1
            action()
        }
    }
}
