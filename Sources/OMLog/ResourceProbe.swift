// @author ixxxxoooo
// 进程资源探针:用 libproc 读取任意同用户进程的 phys_footprint(与 `footprint` 命令同口径)、
// 累计 CPU 时间、线程数与打开的文件描述符数,不起 `ps` 子进程。

import Darwin
import Foundation

/// 一个进程的资源读数。
public struct ProcessUsage: Sendable, Equatable {
    /// 当前物理占用(字节,phys_footprint)。
    public let footprintBytes: UInt64
    /// 进程生命周期内的占用峰值(字节)。
    public let peakFootprintBytes: UInt64
    /// 累计 CPU 时间(纳秒,用户态 + 内核态)。
    public let cpuNanos: UInt64

    public init(footprintBytes: UInt64, peakFootprintBytes: UInt64, cpuNanos: UInt64) {
        self.footprintBytes = footprintBytes
        self.peakFootprintBytes = peakFootprintBytes
        self.cpuNanos = cpuNanos
    }
}

/// 资源探针抽象(测试可注入假数据)。
public protocol ResourceProbing: Sendable {
    /// 读取进程资源;进程不存在或无权限返回 nil。
    func usage(pid: Int32) -> ProcessUsage?
    /// 线程数;读取失败返回 nil。
    func threadCount(pid: Int32) -> Int?
    /// 打开的文件描述符数;读取失败返回 nil。
    func openFileCount(pid: Int32) -> Int?
}

/// 基于 libproc 的系统探针。
public struct SystemResourceProbe: ResourceProbing {
    public init() {}

    /// mach 时间刻度到纳秒的换算(Apple Silicon 上不是 1:1)。
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    public func usage(pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = ticks &* Self.timebase.numer / Self.timebase.denom
        return ProcessUsage(footprintBytes: info.ri_phys_footprint, peakFootprintBytes: info.ri_lifetime_max_phys_footprint, cpuNanos: nanos)
    }

    public func threadCount(pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    public func openFileCount(pid: Int32) -> Int? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.size
    }
}
