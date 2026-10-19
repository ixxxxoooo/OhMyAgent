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
    /// 主 actor 指标的读取闭包与最近一次刷新的缓存值。
    private let mainReaders = Mutex<[String: @MainActor @Sendable () -> Int]>([:])
    private let mainCache = Mutex<[String: Int]>([:])

    public init() {}

    /// 注册(或替换)一个指标。
    /// - Parameters:
    ///   - name: 指标名,建议 `模块.含义`,如 `timeline.entries`
    ///   - read: 读取当前值的闭包
    public func register(_ name: String, _ read: @escaping @Sendable () -> Int) {
        readers.withLock { $0[name] = read }
    }

    /// 注册一个必须在主 actor 读取的指标(如读取 `@Observable` 模型)。
    /// 采样线程不会直接调用它,而是由采样前的 `refreshMain()` 在主线程求值并缓存。
    /// - Parameters:
    ///   - name: 指标名
    ///   - read: 在主 actor 上读取当前值的闭包
    public func registerMain(_ name: String, _ read: @escaping @MainActor @Sendable () -> Int) {
        mainReaders.withLock { $0[name] = read }
    }

    /// 注销一个指标。
    /// - Parameter name: 指标名
    public func unregister(_ name: String) {
        readers.withLock { _ = $0.removeValue(forKey: name) }
        mainReaders.withLock { _ = $0.removeValue(forKey: name) }
        mainCache.withLock { _ = $0.removeValue(forKey: name) }
    }

    /// 在主 actor 上求值全部主 actor 指标并更新缓存(采样前调用)。
    @MainActor
    public func refreshMain() {
        let copy = mainReaders.withLock { $0 }
        guard !copy.isEmpty else { return }
        let values = copy.mapValues { $0() }
        mainCache.withLock { $0 = values }
    }

    /// 读取全部指标的当前值(闭包在锁外执行,避免读取闭包反向注册造成死锁);
    /// 主 actor 指标取最近一次 `refreshMain()` 的缓存。
    public func snapshot() -> [String: Int] {
        let copy = readers.withLock { $0 }
        var result = copy.mapValues { $0() }
        for (name, value) in mainCache.withLock({ $0 }) { result[name] = value }
        return result
    }
}

/// 无界 AsyncStream 的积压计数器:生产端 `produced()`、消费端 `consumed()`,
/// 积压深度 = 已生产 − 已消费。深度持续增长说明消费者跟不上,是内存增长的前兆。
public final class StreamBacklog: Sendable {
    private struct State { var produced = 0; var consumed = 0; var peak = 0; var warned = false }
    private let state = Mutex(State())
    /// 指标名前缀,如 `backlog.acpLines`。
    public let name: String
    /// 积压深度超过它时记一条警告(降回一半以下后才会再次告警);nil 不告警。
    public let warnDepth: Int?

    /// 创建计数器。
    /// - Parameters:
    ///   - name: 指标名前缀
    ///   - warnDepth: 告警阈值(积压深度);nil 不告警
    ///   - registry: 注册到的指标表(缺省为全局;传 nil 不注册,便于测试)
    public init(name: String, warnDepth: Int? = nil, registry: GaugeRegistry? = .shared) {
        self.name = name
        self.warnDepth = warnDepth
        registry?.register("\(name).depth") { [weak self] in self?.depth ?? 0 }
        registry?.register("\(name).peak") { [weak self] in self?.peak ?? 0 }
    }

    /// 生产了 `count` 个元素。
    public func produced(_ count: Int = 1) {
        let crossed = state.withLock { state -> Int? in
            state.produced += count
            let depth = state.produced - state.consumed
            state.peak = max(state.peak, depth)
            guard let limit = warnDepth, depth > limit, !state.warned else { return nil }
            state.warned = true
            return depth
        }
        if let depth = crossed {
            Log.perf.warning("流积压超过阈值,消费者跟不上", ["name": name, "depth": "\(depth)", "limit": "\(warnDepth ?? 0)"])
        }
    }

    /// 消费了 `count` 个元素。
    public func consumed(_ count: Int = 1) {
        state.withLock { state in
            state.consumed += count
            if let limit = warnDepth, state.warned, state.produced - state.consumed <= limit / 2 { state.warned = false }
        }
    }

    /// 当前积压深度。
    public var depth: Int { state.withLock { max($0.produced - $0.consumed, 0) } }
    /// 历史最大积压深度。
    public var peak: Int { state.withLock { $0.peak } }
    /// 是否处于「已越过告警阈值、尚未回落」的状态(测试与诊断用)。
    public var isWarning: Bool { state.withLock { $0.warned } }
}
