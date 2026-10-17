// @author ixxxxoooo
// 子进程登记表与容量指标注册表:
// - ProcessRegistry:各模块在子进程启动/退出时登记 pid 与角色,供资源采样器按角色汇总内存与 CPU;
// - GaugeRegistry:各模块注册「当前容量」读取闭包(条目数、字节数、缓存命中…),仅在采样时才会被调用。

import Foundation
import Synchronization

/// 子进程角色。
public enum ProcessRole: String, Sendable, CaseIterable {
    /// ACP 引擎(claude / node 适配器 / opencode 等)。
    case agent
    /// 终端(用户终端与 Agent 请求的命令)。
    case terminal
    /// 语言服务器。
    case lsp
}

/// 子进程登记表(线程安全)。
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()

    /// 一条登记项。
    public struct Entry: Sendable, Equatable {
        public let pid: Int32
        public let role: ProcessRole
        /// 便于阅读的标识(命令名、会话 id 等,不含参数中的敏感信息)。
        public let label: String
    }

    private let entries = Mutex<[Int32: Entry]>([:])

    public init() {}

    /// 登记一个子进程;pid 非正数忽略,重复登记以最后一次为准。
    /// - Parameters:
    ///   - pid: 进程号
    ///   - role: 角色
    ///   - label: 标识
    public func register(pid: Int32, role: ProcessRole, label: String) {
        guard pid > 0 else { return }
        entries.withLock { $0[pid] = Entry(pid: pid, role: role, label: label) }
    }

    /// 注销子进程(进程退出时调用,未登记的 pid 忽略)。
    /// - Parameter pid: 进程号
    public func unregister(pid: Int32) {
        entries.withLock { _ = $0.removeValue(forKey: pid) }
    }

    /// 当前全部登记项(按 pid 升序)。
    public func snapshot() -> [Entry] {
        entries.withLock { Array($0.values) }.sorted { $0.pid < $1.pid }
    }
}

/// 容量指标注册表(线程安全)。读取闭包会在采样线程上执行,必须线程安全且足够廉价。
public final class GaugeRegistry: @unchecked Sendable {
    public static let shared = GaugeRegistry()

    private let readers = Mutex<[String: @Sendable () -> Int]>([:])

    public init() {}

    /// 注册(或替换)一个指标。
    /// - Parameters:
    ///   - name: 指标名,建议 `模块.含义`,如 `timeline.entries`
    ///   - read: 读取当前值的闭包
    public func register(_ name: String, _ read: @escaping @Sendable () -> Int) {
        readers.withLock { $0[name] = read }
    }

    /// 注销一个指标。
    /// - Parameter name: 指标名
    public func unregister(_ name: String) {
        readers.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// 读取全部指标的当前值(闭包在锁外执行,避免读取闭包反向注册造成死锁)。
    public func snapshot() -> [String: Int] {
        let copy = readers.withLock { $0 }
        return copy.mapValues { $0() }
    }
}
