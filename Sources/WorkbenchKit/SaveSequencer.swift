// @author ixxxxoooo
// 工作台状态落盘序列化器:把 JSON 编码与原子写盘放到后台线程,同时保证「较新的快照永远不会被较旧的覆盖」。
// 快照在主线程取(值类型,`Sendable`),编码与写盘不占主线程。

import Foundation
import os

/// 落盘序列化器:每次保存先领一个递增代号,写盘时只接受不旧于已写入代号的快照。
public final class SaveSequencer: Sendable {
    private struct Gate {
        /// 已发出的最大代号
        var issued = 0
        /// 已写入磁盘的最大代号
        var written = 0
    }

    private let gate = OSAllocatedUnfairLock(initialState: Gate())

    public init() {}

    /// 领取下一个代号(取快照时调用,越晚越大)。
    public func nextGeneration() -> Int {
        gate.withLock { state in
            state.issued += 1
            return state.issued
        }
    }

    /// 写入快照;若已有更新的快照写入过则丢弃本次(返回 false)。
    /// 写盘在锁内串行执行,因此同步保存(退出时)与后台保存不会交错。
    /// - Parameters:
    ///   - generation: 取快照时领取的代号
    ///   - state: 状态快照
    ///   - store: 目标存储
    /// - Returns: 是否真正写入
    @discardableResult
    public func write(generation: Int, state: WorkbenchState, store: WorkbenchStore) throws -> Bool {
        try gate.withLock { gateState in
            guard generation > gateState.written else { return false }
            try store.save(state)
            gateState.written = generation
            return true
        }
    }
}
