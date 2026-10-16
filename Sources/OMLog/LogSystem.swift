// @author ixxxxoooo
// 日志系统:级别过滤、脱敏、os.Logger、文件落盘、内存环形缓冲与订阅、ACP 协议流量日志。

import Foundation
import os

/// 日志系统(进程内单例 `LogSystem.shared`;测试可自建实例)。
public final class LogSystem: @unchecked Sendable {
    public static let shared = LogSystem()

    /// 默认日志目录 `~/Library/Logs/OhMyAgent`。
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OhMyAgent", isDirectory: true)
    }

    /// UserDefaults 键。
    public enum DefaultsKey {
        public static let level = "log.level"
        public static let traffic = "log.traffic"
        public static let hideHome = "log.hideHome"
    }

    private struct State {
        var level: LogLevel = .info
        var traffic = false
        var hideHome = false
        var process = "app"
        var nextID: UInt64 = 1
        var ring: [LogEntry] = []
        var continuations: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
        var writer: LogFileWriter?
        var trafficWriter: LogFileWriter?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ringCapacity = 2000
    private var loggers: [LogCategory: Logger] = [:]
    private let osEnabled: Bool

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
        let snapshot = state.withLock { ($0.level, $0.hideHome, $0.writer) }
        guard level >= snapshot.0 else { return }
        let hide = snapshot.1
        let text = LogRedactor.redact(message(), hideHome: hide)
        let safeFields = fields.mapValues { LogRedactor.redact($0, hideHome: hide) }
        let entry: LogEntry = state.withLock { state in
            let entry = LogEntry(id: state.nextID, date: Date(), level: level, category: category, message: text, fields: safeFields, process: state.process)
            state.nextID += 1
            state.ring.append(entry)
            if state.ring.count > ringCapacity { state.ring.removeFirst(state.ring.count - ringCapacity) }
            for continuation in state.continuations.values { continuation.yield(entry) }
            return entry
        }
        snapshot.2?.append(entry.line)
        if osEnabled, let logger = loggers[category] {
            let line = entry.line
            switch level {
            case .debug: logger.debug("\(line, privacy: .public)")
            case .info: logger.info("\(line, privacy: .public)")
            case .warning: logger.warning("\(line, privacy: .public)")
            case .error: logger.error("\(line, privacy: .public)")
            }
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
        let body = LogRedactor.truncate(LogRedactor.redact(payload(), hideHome: hide))
        trafficWriter.append("\(LogFormat.timestamp(Date())) \(direction) \(summary)\(body.isEmpty ? "" : " " + body.replacingOccurrences(of: "\n", with: "\\n"))")
    }

    /// 最近的日志(新→旧不保证,按时间升序返回)。
    /// - Parameter limit: 最多条数
    public func recent(limit: Int = 500) -> [LogEntry] {
        state.withLock { Array($0.ring.suffix(limit)) }
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

    /// 自给定起点起经过的毫秒数。
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
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
