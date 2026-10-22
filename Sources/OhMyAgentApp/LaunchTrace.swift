// @author ixxxxoooo
// 启动分段计时:从内核记录的进程启动时间起,在各关键节点写一条「启动阶段」日志,
// 用于判断启动慢在 dyld、初始化、工作台加载、引导还是首帧。

import Foundation
import OMLog
import os

/// 启动阶段打点(线程安全):除距进程启动的累计毫秒外,还记录相对上一阶段的增量,直接看出哪一段最慢。
enum LaunchTrace {
    /// 进程启动时间(与诊断页首帧口径一致)。
    private static let start = DiagnosticsStore.processStartDate() ?? Date()
    /// 上一个阶段的累计毫秒(用于计算增量)。
    private static let lastMs = OSAllocatedUnfairLock(initialState: 0)

    /// 记录一个启动阶段。
    /// - Parameter stage: 阶段名,如 `AppDelegate 启动完成`
    static func mark(_ stage: String) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let delta = lastMs.withLock { last -> Int in
            defer { last = ms }
            return max(ms - last, 0)
        }
        PerfStats.shared.record(name: "启动:" + stage, micros: delta * 1000)
        Log.perf.info("启动阶段", ["stage": stage, "sinceLaunchMs": "\(ms)", "deltaMs": "\(delta)"])
    }
}
