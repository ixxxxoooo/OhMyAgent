// @author ygw
// 诊断计时:记录启动到首帧的耗时,供「设置 → 诊断」与性能门槛检查使用。

import Foundation

/// 启动计时(主线程使用)。
@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()
    private(set) var launchDate = Date()
    private(set) var firstFrameDate: Date?

    /// 记录进程启动时间点。
    func markLaunch() { launchDate = Date() }

    /// 记录首帧(只记录第一次)。
    func markFirstFrame() { if firstFrameDate == nil { firstFrameDate = Date() } }

    /// 启动到首帧的耗时(毫秒)。
    var firstFrameMilliseconds: Int? { firstFrameDate.map { Int($0.timeIntervalSince(launchDate) * 1000) } }
}
