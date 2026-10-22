// @author ixxxxoooo
// 日志系统:级别过滤、脱敏、os.Logger、文件落盘、内存环形缓冲与订阅、ACP 协议流量日志。

import Foundation
import os

/// 日志系统(进程内单例 `LogSystem.shared`;测试可自建实例)。
public final class LogSystem: @unchecked Sendable {
    public static let shared = LogSystem()

    /// 默认日志目录 `~/Library/Logs/OhMyAgent`。
    public static var defaultDirectory: URL {
        AppEnv.logsDirectory
    }

    /// UserDefaults 键。
    public enum DefaultsKey {
        public static let level = "log.level"
        /// 按分类覆盖级别的键前缀,如 `log.level.perf`。
        public static let categoryLevelPrefix = "log.level."
        public static let traffic = "log.traffic"
        public static let hideHome = "log.hideHome"
    }

    private struct State {
        var level: LogLevel = .info
        /// 按分类覆盖的级别(优先于全局级别)。
        var categoryLevels: [LogCategory: LogLevel] = [:]
        var traffic = false
        var hideHome = false
        var process = "app"
        var nextID: UInt64 = 1
        var ring = LogRing(capacity: 2000)
        var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
        var writer: LogFileWriter?
        var trafficWriter: LogFileWriter?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// 后台串行队列:脱敏、行格式化、环形缓冲、订阅分发、落盘与 os.Logger 都在这里完成,调用线程只做入队。
    private let queue = DispatchQueue(label: "com.ixxxxoooo.OhMyAgent.logsystem", qos: .utility)
    /// 已入队未处理的条数(洪泛保护)。
    private let pendingCount = OSAllocatedUnfairLock(initialState: 0)
    /// 待处理条数上限:超过后丢弃 debug 级别,避免日志洪泛时内存无界增长。
    private static let pendingLimit = 20_000
    /// 被洪泛保护丢弃的条数(下次处理时汇报一次)。
    private let droppedCount = OSAllocatedUnfairLock(initialState: 0)
    private var loggers: [LogCategory: Logger] = [:]
    private let osEnabled: Bool
    private static let pidText = "\(ProcessInfo.processInfo.processIdentifier)"

    /// 创建日志系统。
    /// - Parameters:
    ///   - directory: 日志目录;nil 表示不写文件(仅内存与 os.Logger)
    ///   - process: 进程标签(非 app 时文件名带上它)
    ///   - level: 初始级别
    ///   - osLog: 是否同时写入统一日志
    public init(directory: URL? = nil, process: String = "app", level: LogLevel = .info, osLog: Bool = true) {
        osEnabled = osLog
        for category in LogCategory.allCases { loggers[category] = Logger(subsystem: "com.ixxxxoooo.OhMyAgent", category: category.rawValue) }
        state.withLock { $0.level = level; $0.process = process }
        if let directory { attachFiles(directory: directory, process: process) }
    }

    /// 挂接文件落盘(可重复调用,以最后一次为准)。
    /// - Parameters:
    ///   - directory: 日志目录
    ///   - process: 进程标签,决定文件名前缀
    public func attachFiles(directory: URL, process: String) {
        let prefix = process == "app" ? "oma" : "oma-\(process.lowercased())"
        let main = LogFileWriter(directory: directory, prefix: prefix)
        let traffic = LogFileWriter(directory: directory, prefix: "acp-traffic", maxBytes: 20 * 1024 * 1024, maxFiles: 3, retentionDays: 3)
        state.withLock { $0.writer = main; $0.trafficWriter = traffic; $0.process = process }
    }

    /// 日志目录(未落盘时为 nil)。
    public var directory: URL? { state.withLock { $0.writer?.directory } }

    /// 当前级别。
    public var level: LogLevel {
        get { state.withLock { $0.level } }
        set { state.withLock { $0.level = newValue } }
    }

    /// 某分类的生效级别(有覆盖用覆盖,否则用全局级别)。
    /// - Parameter category: 分类
    public func level(for category: LogCategory) -> LogLevel {
        state.withLock { $0.categoryLevels[category] ?? $0.level }
    }

    /// 单独设置某分类的级别,传 nil 清除覆盖。
    /// - Parameters:
    ///   - level: 级别;nil 表示跟随全局
    ///   - category: 分类
    public func setLevel(_ level: LogLevel?, for category: LogCategory) {
        state.withLock { $0.categoryLevels[category] = level }
    }

    /// 是否记录 ACP 协议流量。
    public var trafficEnabled: Bool {
        get { state.withLock { $0.traffic } }
        set { state.withLock { $0.traffic = newValue } }
    }

    /// 是否把家目录替换为 `~`。
    public var hideHome: Bool {
        get { state.withLock { $0.hideHome } }
        set { state.withLock { $0.hideHome = newValue } }
    }

    /// 从 UserDefaults 与环境变量读取配置(`OMA_LOG_LEVEL` 优先)。
    public func loadConfiguration(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let text = environment["OMA_LOG_LEVEL"], let value = LogLevel(text: text) { level = value }
        else if let text = defaults.string(forKey: DefaultsKey.level), let value = LogLevel(text: text) { level = value }
        for category in LogCategory.allCases {
            let envKey = "OMA_LOG_LEVEL_" + category.rawValue.uppercased()
            if let text = environment[envKey], let value = LogLevel(text: text) { setLevel(value, for: category) }
            else if let text = defaults.string(forKey: DefaultsKey.categoryLevelPrefix + category.rawValue), let value = LogLevel(text: text) { setLevel(value, for: category) }
        }
        trafficEnabled = environment["OMA_LOG_TRAFFIC"] == "1" || defaults.bool(forKey: DefaultsKey.traffic)
        hideHome = defaults.bool(forKey: DefaultsKey.hideHome)
    }

    /// 记录一条日志。
    /// - Parameters:
    ///   - level: 级别
    ///   - category: 分类
    ///   - message: 延迟求值的消息(级别不满足时不会计算)
    ///   - fields: 附加键值
    public func log(_ level: LogLevel, _ category: LogCategory, _ message: @autoclosure () -> String, fields: [String: String] = [:]) {
        let gate: (id: UInt64, process: String)? = state.withLock { state in
            guard level >= (state.categoryLevels[category] ?? state.level) else { return nil }
            defer { state.nextID += 1 }
            return (state.nextID, state.process)
        }
        guard let gate else { return }
        let pending = PendingLog(id: gate.id, date: Date(), level: level, category: category, message: message(), fields: fields, process: gate.process)
        // error 级别同步处理:崩溃前的最后几条错误必须落盘;同时保证与此前入队的条目顺序一致
        if level == .error {
            queue.sync { self.process(pending) }
            return
        }
        let over = pendingCount.withLock { count -> Bool in
            if level == .debug, count >= Self.pendingLimit { return true }
            count += 1
            return false
        }
        if over { droppedCount.withLock { $0 += 1 }; return }
        queue.async { [self] in
            process(pending)
            pendingCount.withLock { $0 -= 1 }
        }
    }

    /// 在后台队列上完成一条日志的脱敏、格式化、缓冲、分发与落盘。
    /// - Parameter pending: 调用线程采集的原始日志
    private func process(_ pending: PendingLog) {
        let (hide, writer) = state.withLock { ($0.hideHome, $0.writer) }
        let text = LogRedactor.redact(pending.message, hideHome: hide)
        var redacted = pending.fields.mapValues { LogRedactor.redact($0, hideHome: hide) }
        // 多个进程(开发版、安装版、辅助进程)可能写同一个日志目录:每行带 pid,报告才能按进程拆分
        if redacted["pid"] == nil { redacted["pid"] = Self.pidText }
        let entry = LogEntry(id: pending.id, date: pending.date, level: pending.level, category: pending.category, message: text, fields: redacted, process: pending.process)
        state.withLock { state in
            state.ring.append(entry)
            for continuation in state.continuations.values { continuation.yield(entry) }
        }
        let line = entry.line
        writer?.append(line)
        if osEnabled, let logger = loggers[pending.category] {
            switch pending.level {
            case .debug: logger.debug("\(line, privacy: .public)")
            case .info: logger.info("\(line, privacy: .public)")
            case .warning: logger.warning("\(line, privacy: .public)")
            case .error: logger.error("\(line, privacy: .public)")
            }
        }
        let dropped = droppedCount.withLock { value -> Int in defer { value = 0 }; return value }
        if dropped > 0 {
            log(.warning, .log, "日志洪泛,已丢弃 debug 日志", fields: ["dropped": "\(dropped)"])
        }
    }

    /// 记录 ACP 协议流量(仅在开启时写 `acp-traffic-*.log`)。
    /// - Parameters:
    ///   - direction: `→`(发出)或 `←`(收到)
    ///   - summary: 方法名与 id 等摘要
    ///   - payload: 载荷文本(会被脱敏并截断)
    public func traffic(_ direction: String, _ summary: String, payload: @autoclosure () -> String = "") {
        let (enabled, hide, trafficWriter) = state.withLock { ($0.traffic, $0.hideHome, $0.trafficWriter) }
        guard enabled, let trafficWriter else { return }
        let raw = payload()
        let date = Date()
        // 脱敏与截断较重(载荷可达数百 KB),放到后台队列
        queue.async {
            let body = LogRedactor.truncate(LogRedactor.redact(raw, hideHome: hide))
            trafficWriter.append("\(LogFormat.timestamp(date)) \(direction) \(summary)\(body.isEmpty ? "" : " " + body.replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }

    /// 最近的日志(新→旧不保证,按时间升序返回)。
    /// - Parameter limit: 最多条数
    public func recent(limit: Int = 500) -> [LogEntry] {
        queue.sync {}   // 先排空后台队列,保证读到此前所有日志
        return state.withLock { $0.ring.suffix(limit) }
    }

    /// 订阅新日志(用于输出面板实时尾随)。
    public func stream() -> AsyncStream<LogEntry> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// 等待文件写入完成。
    public func flush() {
        queue.sync {}
        let (a, b) = state.withLock { ($0.writer, $0.trafficWriter) }
        a?.flush(); b?.flush()
    }
}

/// 绑定了分类与固定上下文的日志器。
public struct OMLogger: Sendable {
    public let category: LogCategory
    private let system: LogSystem
    private let context: [String: String]

    /// 创建日志器。
    /// - Parameters:
    ///   - category: 分类
    ///   - system: 日志系统
    ///   - context: 每条日志都携带的字段(如 session)
    public init(_ category: LogCategory, system: LogSystem = .shared, context: [String: String] = [:]) {
        self.category = category; self.system = system; self.context = context
    }

    /// 派生带额外上下文的日志器。
    /// - Parameter extra: 追加字段
    public func with(_ extra: [String: String]) -> OMLogger {
        OMLogger(category, system: system, context: context.merging(extra) { $1 })
    }

    public func debug(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        system.log(.debug, category, message(), fields: context.merging(fields) { $1 })
    }
    public func info(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        system.log(.info, category, message(), fields: context.merging(fields) { $1 })
    }
    public func warning(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        system.log(.warning, category, message(), fields: context.merging(fields) { $1 })
    }
    public func error(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        system.log(.error, category, message(), fields: context.merging(fields) { $1 })
    }

    /// 记录错误并带上 `error=` 字段。
    /// - Parameters:
    ///   - message: 描述(发生了什么操作)
    ///   - error: 错误
    ///   - fields: 附加字段
    public func error(_ message: @autoclosure () -> String, error: Error, _ fields: [String: String] = [:]) {
        var all = fields
        all["error"] = String(describing: error)
        system.log(.error, category, message(), fields: context.merging(all) { $1 })
    }

    /// 计时执行并在 debug 级别记录耗时,超过阈值升级为 warning。
    /// - Parameters:
    ///   - name: 操作名
    ///   - warnAfter: 超过该秒数记为 warning
    ///   - body: 要执行的同步代码
    public func measure<T>(_ name: String, warnAfter: Double = 1.0, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let ms = Self.milliseconds(since: start)
            if Double(ms) / 1000 >= warnAfter { warning("\(name) 耗时较长", ["ms": "\(ms)"]) } else { debug("\(name) 完成", ["ms": "\(ms)"]) }
        }
        return try body()
    }

    /// 自给定起点起经过的毫秒数(全仓库统一计时口径,禁止再手写 `components.seconds * 1000`)。
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        microseconds(since: start) / 1000
    }

    /// 自给定起点起经过的微秒数。
    public static func microseconds(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1_000_000 + d.components.attoseconds / 1_000_000_000_000)
    }

    /// 记录协议流量。
    public func traffic(_ direction: String, _ summary: String, payload: @autoclosure () -> String = "") {
        system.traffic(direction, summary, payload: payload())
    }
}

/// 全局日志器入口:`Log.app.info("…")`。
public enum Log {
    public static let app = OMLogger(.app)
    public static let acp = OMLogger(.acp)
    public static let agent = OMLogger(.agent)
    public static let session = OMLogger(.session)
    public static let tool = OMLogger(.tool)
    public static let bridge = OMLogger(.bridge)
    public static let ui = OMLogger(.ui)
    public static let editor = OMLogger(.editor)
    public static let lsp = OMLogger(.lsp)
    public static let git = OMLogger(.git)
    public static let terminal = OMLogger(.terminal)
    public static let config = OMLogger(.config)
    public static let perf = OMLogger(.perf)
    public static let update = OMLogger(.update)
    public static let log = OMLogger(.log)

    /// 初始化全局日志(应在进程入口最先调用一次)。
    /// - Parameters:
    ///   - process: 进程标签,如 app / OhMyAgentBridge
    ///   - directory: 日志目录
    public static func bootstrap(process: String = "app", directory: URL = LogSystem.defaultDirectory) {
        LogSystem.shared.attachFiles(directory: directory, process: process)
        LogSystem.shared.loadConfiguration()
        let info = Bundle.main.infoDictionary
        Log.log.info("日志系统启动", [
            "process": process,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "level": "\(LogSystem.shared.level)",
            "version": "\(info?["CFBundleShortVersionString"] as? String ?? "-")(\(info?["CFBundleVersion"] as? String ?? "-"))",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }
}

/// 调用线程采集、尚未脱敏与格式化的日志。
private struct PendingLog: Sendable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let fields: [String: String]
    let process: String
}

/// 固定容量环形缓冲:追加 O(1),避免数组 `removeFirst` 的整体搬移。
struct LogRing: Sendable {
    private var storage: [LogEntry] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = max(capacity, 1) }

    /// 追加一条;满后覆盖最旧的一条。
    mutating func append(_ entry: LogEntry) {
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[head] = entry
            head = (head + 1) % capacity
        }
    }

    /// 按时间升序返回最近 `limit` 条。
    func suffix(_ limit: Int) -> [LogEntry] {
        let count = storage.count
        let take = min(max(limit, 0), count)
        guard take > 0 else { return [] }
        let start = count - take
        return (start..<count).map { storage[(head + $0) % count] }
    }
}
