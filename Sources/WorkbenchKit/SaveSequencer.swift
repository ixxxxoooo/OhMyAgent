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
        /// 最近一次写入的字节(相同则跳过写盘)
        var lastData: Data?
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
    /// JSON 编码在锁外完成(只占调用线程),锁内只做代号比较与原子写盘,因此同步保存(退出时)与后台保存不会交错,
    /// 也不会因编码耗时让另一路保存干等;字节与上次写入完全相同时跳过写盘。
    /// - Parameters:
    ///   - generation: 取快照时领取的代号
    ///   - state: 状态快照
    ///   - store: 目标存储
    /// - Returns: 是否真正写入
    @discardableResult
    public func write(generation: Int, state: WorkbenchState, store: WorkbenchStore) throws -> Bool {
        let data = try store.encode(state)
        return try gate.withLock { gateState in
            guard generation > gateState.written else { return false }
            if gateState.lastData == data, FileManager.default.fileExists(atPath: store.fileURL.path) {
                gateState.written = generation
                return false
            }
            try store.write(data)
            gateState.written = generation
            gateState.lastData = data
            return true
        }
    }
}
