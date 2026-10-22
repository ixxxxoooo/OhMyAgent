// @author ixxxxoooo
// 卡顿栈采样:主线程停滞超过阈值后,由进程内看门狗线程每 10~20ms 挂起主线程读一次调用栈(`MainThreadStackProbe`),
// 直到这次卡顿结束;结束时按真实时长聚合、符号化并落盘(`hitch-<pid>-<序号>-<毫秒>ms.txt`),日志 WARN「卡顿栈」。
// 开发版 / 演示模式 ≥250ms 即采;正式版 ≥1s 开始采、总时长 ≥2s 才落盘(`OMA_HITCH_SAMPLE=0` 可关闭);只记录符号,不含任何载荷与密钥。

import Foundation
import Synchronization

/// 采样节流策略(纯逻辑,便于测试):两次卡顿会话之间的最小间隔与单进程最大会话数。
public struct HitchSamplePolicy: Sendable, Equatable {
    /// 主线程停滞达到该毫秒数才触发采样
    public var stallThresholdMs: Int
    /// 两次卡顿会话的最小间隔(毫秒)
    public var minGapMs: Int
    /// 单进程最多记录的卡顿会话数
    public var maxSamples: Int
    /// 总时长达到该毫秒数才落盘(短于它的会话只采样、不写文件)
    public var persistThresholdMs: Int

    /// - Parameters:
    ///   - stallThresholdMs: 开始采样的停滞阈值,默认 250
    ///   - minGapMs: 两次会话的最小间隔,默认 500
    ///   - maxSamples: 最大会话数,默认 60
    ///   - persistThresholdMs: 落盘的最短总时长,默认等于 `stallThresholdMs`
    public init(stallThresholdMs: Int = 250, minGapMs: Int = 500, maxSamples: Int = 60, persistThresholdMs: Int? = nil) {
        self.stallThresholdMs = max(stallThresholdMs, 50)
        self.minGapMs = max(minGapMs, 0)
        self.maxSamples = max(maxSamples, 0)
        self.persistThresholdMs = max(persistThresholdMs ?? self.stallThresholdMs, 0)
    }

    /// 按构建环境选择策略:开发版/演示 250ms 即采并全部落盘;正式版 1s 开始采、≥2s 才落盘。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func forEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> HitchSamplePolicy {
        let verbose = AppEnv.isDev(environment: environment) || environment["OMA_DEMO"] == "1" || environment["OMA_HITCH_SAMPLE"] == "1"
        return verbose ? HitchSamplePolicy() : HitchSamplePolicy(stallThresholdMs: 1000, persistThresholdMs: 2000)
    }

    /// 是否应当采样。
    /// - Parameters:
    ///   - stalledMs: 主线程已停滞的毫秒数
    ///   - sinceLastMs: 距上次采样的毫秒数;nil 表示还没采过
    ///   - taken: 已采样次数
    /// - Returns: 满足阈值、间隔与次数上限时为 true
    public func shouldSample(stalledMs: Int, sinceLastMs: Int?, taken: Int) -> Bool {
        guard taken < maxSamples, stalledMs >= stallThresholdMs else { return false }
        if let sinceLastMs, sinceLastMs < minGapMs { return false }
        return true
    }
}

/// 旧版 `sample` 输出解析:提取主线程调用图中「采样数最多」的那条路径(用于分析历史采样文件与手动 `sample` 结果)。
public enum HitchSampleParser {
    /// 调用图节点。
    private final class Node {
        let column: Int
        let count: Int
        let text: String
        var children: [Node] = []
        init(column: Int, count: Int, text: String) { self.column = column; self.count = count; self.text = text }
    }

    /// 解析 `sample` 文本,返回主线程最重路径(从根到叶)的帧描述。
    /// - Parameters:
    ///   - text: `sample` 命令输出全文
    ///   - maxFrames: 最多返回的帧数(保留靠近叶子的部分)
    /// - Returns: 帧描述(`符号 (in 模块)`);找不到主线程时返回空数组
    public static func heaviestMainPath(in text: String, maxFrames: Int = 14) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("Call graph:") }) else { return [] }
        var root: Node?
        var stack: [Node] = []
        var inMain = false
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inMain { break }
                continue
            }
            guard let node = parseLine(line) else { continue }
            // 线程行:列最小(通常为 4),含队列名;主线程带 com.apple.main-thread
            if !line.contains("+") || node.column <= 4 {
                if inMain { break }
                if line.contains("com.apple.main-thread") {
                    inMain = true
                    root = node
                    stack = [node]
                }
                continue
            }
            guard inMain else { continue }
            while let top = stack.last, top.column >= node.column { stack.removeLast() }
            stack.last?.children.append(node)
            stack.append(node)
        }
        guard var current = root else { return [] }
        var path: [String] = []
        while let next = current.children.max(by: { $0.count < $1.count }) {
            path.append(next.text)
            current = next
        }
        return Array(path.suffix(max(maxFrames, 1)))
    }

    /// 解析一行:去掉前导树形符号后读取「次数 符号描述」。
    private static func parseLine(_ line: String) -> Node? {
        let scalars = Array(line)
        var index = 0
        while index < scalars.count, " +!:|".contains(scalars[index]) { index += 1 }
        guard index < scalars.count, scalars[index].isNumber else { return nil }
        var end = index
        while end < scalars.count, scalars[end].isNumber { end += 1 }
        guard let count = Int(String(scalars[index..<end])) else { return nil }
        let rest = String(scalars[end...]).trimmingCharacters(in: .whitespaces)
        return Node(column: index, count: count, text: simplify(rest))
    }

    /// 精简帧描述:去掉偏移与地址,保留「符号 (in 模块)」。
    private static func simplify(_ raw: String) -> String {
        var text = raw
        if let bracket = text.range(of: "  [0x") { text = String(text[..<bracket.lowerBound]) }
        if let plus = text.range(of: ") + ") { text = String(text[..<plus.lowerBound]) + ")" }
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        return text
    }
}

/// 一次卡顿内的栈聚合(纯逻辑,便于测试):按「完整栈」去重计数。
public struct HitchStackAggregator: Sendable {
    /// 一种出现过的栈及次数
    public struct Entry: Sendable, Equatable {
        /// 栈地址(栈顶在前)
        public let frames: [UInt]
        /// 出现次数
        public var count: Int
    }

    /// 总采样次数
    public private(set) var total = 0
    private var entries: [[UInt]: Int] = [:]
    /// 最多保留的不同栈数,防止内存无限增长
    private let maxDistinct: Int

    /// - Parameter maxDistinct: 最多保留的不同栈数,默认 512
    public init(maxDistinct: Int = 512) { self.maxDistinct = max(maxDistinct, 1) }

    /// 记入一次采样;空栈被忽略。
    /// - Parameter frames: 栈地址(栈顶在前)
    public mutating func add(_ frames: [UInt]) {
        guard !frames.isEmpty else { return }
        total += 1
        if entries[frames] != nil || entries.count < maxDistinct { entries[frames, default: 0] += 1 }
    }

    /// 出现次数最多的若干种栈(次数相同按地址序,保证确定性)。
    /// - Parameter limit: 返回数量
    public func top(_ limit: Int) -> [Entry] {
        entries.map { Entry(frames: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.frames.lexicographicallyPrecedes($1.frames) }
            .prefix(max(limit, 0)).map { $0 }
    }
}

/// 采样文件名与清理规则(纯逻辑,便于测试)。
public enum HitchSampleFiles {
    /// 长卡顿阈值:总时长不小于它的文件不参与「保留最近 N 份」的清理,单独限量
    public static let longStallMs = 5000

    /// 文件名:`hitch-<pid>-<序号>-<总毫秒>ms.txt`。
    public static func fileName(pid: Int32, sequence: Int, totalMs: Int) -> String {
        "hitch-\(pid)-\(sequence)-\(totalMs)ms.txt"
    }

    /// 从文件名解析总毫秒;旧格式(无时长)返回 nil。
    public static func totalMs(of fileName: String) -> Int? {
        guard fileName.hasPrefix("hitch-"), fileName.hasSuffix("ms.txt") else { return nil }
        let stem = fileName.dropLast("ms.txt".count)
        guard let last = stem.split(separator: "-").last else { return nil }
        return Int(last)
    }

    /// 需要删除的文件:短卡顿保留最近 `shortLimit` 份,长卡顿保留最近 `longLimit` 份。
    /// - Parameters:
    ///   - files: 文件名与修改时间
    ///   - shortLimit: 短卡顿保留数
    ///   - longLimit: 长卡顿保留数
    /// - Returns: 应删除的文件名
    public static func victims(files: [(name: String, modified: Date)], shortLimit: Int, longLimit: Int) -> [String] {
        let samples = files.filter { $0.name.hasPrefix("hitch-") && $0.name.hasSuffix(".txt") }
        func isLong(_ name: String) -> Bool { (totalMs(of: name) ?? 0) >= longStallMs }
        var result: [String] = []
        for (group, limit) in [(samples.filter { !isLong($0.name) }, shortLimit), (samples.filter { isLong($0.name) }, longLimit)] {
            let sorted = group.sorted { $0.modified > $1.modified }
            if sorted.count > limit { result += sorted.dropFirst(max(limit, 0)).map(\.name) }
        }
        return result
    }
}

/// 卡顿栈采样器(进程内单例):由 `MainThreadHitchMonitor` 在检测到停滞时驱动,卡顿结束时收尾。
public final class HitchStackSampler: @unchecked Sendable {
    public static let shared = HitchStackSampler()

    private struct State {
        var taken = 0
        var lastEndAt: ContinuousClock.Instant?
        var running = false
        /// 卡顿结束时由主线程回调写入的总时长
        var endedMs: Int?
        /// 最近一次卡顿结束的时刻(用来丢弃「探针已被执行、监视器才来报告」的过期通知)
        var lastStallEndAt: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let probe = Mutex<MainThreadStackProbe?>(nil)
    private let queue = DispatchQueue(label: "oma.hitch-sampler", qos: .userInteractive)
    /// 采样节流策略
    public let policy: HitchSamplePolicy
    /// 采样间隔(毫秒):开发版更密
    private let intervalMs: Int
    /// 单次卡顿最长采样时长(毫秒),防止主线程永久挂死时无限采样
    private let maxSessionMs = 120_000

    /// - Parameters:
    ///   - policy: 节流策略
    ///   - intervalMs: 采样间隔毫秒,默认 10
    public init(policy: HitchSamplePolicy = .forEnvironment(), intervalMs: Int = 10) {
        self.policy = policy
        self.intervalMs = max(intervalMs, 2)
    }

    /// 是否启用:显式 `OMA_HITCH_SAMPLE=1` 或开发版 / 演示模式为「详细模式」;正式版默认也启用(≥1s 才采、≥2s 才落盘),`OMA_HITCH_SAMPLE=0` 关闭。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let flag = environment["OMA_HITCH_SAMPLE"] { return flag == "1" }
        return AppEnv.isDev(environment: environment) || environment["OMA_DEMO"] == "1"
    }

    /// 是否应当采样(含正式版):只有 `OMA_HITCH_SAMPLE=0` 才完全关闭。
    public static func isSamplingAllowed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["OMA_HITCH_SAMPLE"] != "0"
    }

    /// 绑定主线程探针(必须在主线程调用)。
    public func attachMainThread() {
        guard let created = MainThreadStackProbe() else { return }
        probe.withLock { $0 = created }
    }

    /// 主线程已停滞 `stalledMs` 毫秒(监视器每 50ms 调用一次):满足条件时启动一个采样会话,会话内部连续采样直到卡顿结束。
    /// - Parameters:
    ///   - stalledMs: 已停滞毫秒数
    ///   - postedAt: 本次未被执行的探针的投递时刻
    public func stallDetected(stalledMs: Int, postedAt: ContinuousClock.Instant) {
        guard probe.withLock({ $0 != nil }) else { return }
        let now = ContinuousClock.now
        let sequence: Int? = state.withLock { value in
            if let ended = value.lastStallEndAt, ended >= postedAt { return nil }
            let since = value.lastEndAt.map { Int(OMLogger.milliseconds(since: $0)) }
            guard !value.running, policy.shouldSample(stalledMs: stalledMs, sinceLastMs: since, taken: value.taken) else { return nil }
            value.running = true
            value.endedMs = nil
            value.taken += 1
            return value.taken
        }
        guard let sequence else { return }
        let startedAt = now - .milliseconds(stalledMs)
        queue.async { [self] in runSession(sequence: sequence, startedAt: startedAt) }
    }

    /// 卡顿结束(主线程探针终于被执行):告知会话总时长,会话随后收尾落盘。
    /// - Parameter totalMs: 这次卡顿的总毫秒数
    public func stallEnded(totalMs: Int) {
        state.withLock { value in
            value.lastStallEndAt = .now
            if value.running { value.endedMs = totalMs }
        }
    }

    /// 采样会话:每个间隔挂起主线程读一次栈,直到卡顿结束或超过上限,然后聚合、符号化、写文件。
    private func runSession(sequence: Int, startedAt: ContinuousClock.Instant) {
        guard let activeProbe = probe.withLock({ $0 }) else {
            state.withLock { $0.running = false }
            return
        }
        let capacity = 96
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var aggregator = HitchStackAggregator()
        var totalMs = 0
        while true {
            let count = activeProbe.capture(into: buffer, capacity: capacity)
            if count > 0 { aggregator.add(Array(UnsafeBufferPointer(start: buffer, count: count))) }
            usleep(UInt32(intervalMs * 1000))
            let ended = state.withLock { $0.endedMs }
            let elapsed = Int(OMLogger.milliseconds(since: startedAt))
            if let ended { totalMs = ended; break }
            if elapsed >= maxSessionMs { totalMs = elapsed; break }
        }
        state.withLock { value in
            value.running = false
            value.lastEndAt = .now
        }
        guard aggregator.total > 0, totalMs >= policy.persistThresholdMs else { return }
        report(aggregator, sequence: sequence, totalMs: totalMs)
    }

    /// 符号化并写文件 + 日志。
    private func report(_ aggregator: HitchStackAggregator, sequence: Int, totalMs: Int) {
        let tops = aggregator.top(5)
        guard let best = tops.first else { return }
        // 日志里的「最重路径」:最频繁的栈,从根到叶,保留靠近叶子的 14 帧
        let path = best.frames.reversed().suffix(14).map(StackSymbolizer.describe)
        let pid = ProcessInfo.processInfo.processIdentifier
        let directory = AppEnv.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = HitchSampleFiles.fileName(pid: pid, sequence: sequence, totalMs: totalMs)
        var text = "卡顿 \(totalMs)ms,采样 \(aggregator.total) 次(间隔约 \(intervalMs)ms),pid=\(pid)\n\n"
        for (index, entry) in tops.enumerated() {
            text += "#\(index + 1) 出现 \(entry.count)/\(aggregator.total) 次(从栈顶到栈底)\n"
            for frame in entry.frames.prefix(60) { text += "    \(StackSymbolizer.describe(frame))\n" }
            text += "\n"
        }
        do {
            try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            Log.perf.warning("卡顿栈写文件失败", ["error": "\(error)", "file": name])
        }
        Log.perf.warning("卡顿栈", ["stalledMs": "\(totalMs)", "samples": "\(aggregator.total)", "file": name, "top": path.joined(separator: " > ")])
        pruneOldSamples(in: directory)
    }

    /// 清理旧采样文件:短卡顿保留最近 20 份,长卡顿(≥5s)保留最近 40 份。
    private func pruneOldSamples(in directory: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let files = urls.map { url in
            (name: url.lastPathComponent, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for name in HitchSampleFiles.victims(files: files, shortLimit: 20, longLimit: 40) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
