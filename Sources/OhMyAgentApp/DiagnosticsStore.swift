// @author ixxxxoooo
// 诊断计时:记录进程启动到首帧的耗时,供「设置 → 诊断」与性能门槛检查使用。

import Foundation
import Darwin
import OMLog

/// 启动计时(主线程使用)。
@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    /// 进程真实启动时间(内核记录,包含 dyld 与运行时初始化);读取失败时回退为首次访问时间。
    private(set) var launchDate = DiagnosticsStore.processStartDate() ?? Date()
    private(set) var firstFrameDate: Date?

    /// 保留接口:不再重置启动时间,以内核记录的进程启动时间为准。
    func markLaunch() {}

    /// 记录首帧(只记录第一次);设置环境变量 `OMA_PERF_OUT` 时把耗时写入该文件(性能门槛脚本使用)。
    func markFirstFrame() {
        guard firstFrameDate == nil else { return }
        firstFrameDate = Date()
        if let ms = firstFrameMilliseconds { Log.perf.info("首帧", ["ms": "\(ms)"]) }
        if let path = ProcessInfo.processInfo.environment["OMA_PERF_OUT"], !path.isEmpty, let ms = firstFrameMilliseconds {
            try? "\(ms)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 启动到首帧的耗时(毫秒)。
    var firstFrameMilliseconds: Int? { firstFrameDate.map { Int($0.timeIntervalSince(launchDate) * 1000) } }

    /// 通过 sysctl 读取当前进程的启动时间。
    /// - Returns: 启动时间;失败返回 nil。
    nonisolated static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
