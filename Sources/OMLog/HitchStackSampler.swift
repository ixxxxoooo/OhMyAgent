// @author ixxxxoooo
// 卡顿栈采样:主线程停滞超过阈值时,由后台调用系统 `sample` 抓取本进程调用栈,
// 把主线程「最重路径」的栈顶若干帧写入 perf 日志,并保留完整采样文件供深入分析。
// 只在开发版 / 演示模式 / 显式 `OMA_HITCH_SAMPLE=1` 时启用;只记录符号,不含任何载荷与密钥。

import Foundation
import Synchronization

/// 采样节流策略(纯逻辑,便于测试):两次采样之间的最小间隔与单进程最大次数。
public struct HitchSamplePolicy: Sendable, Equatable {
    /// 主线程停滞达到该毫秒数才触发采样
    public var stallThresholdMs: Int
    /// 两次采样的最小间隔(毫秒)
    public var minGapMs: Int
    /// 单进程最多采样次数
    public var maxSamples: Int

    /// - Parameters:
    ///   - stallThresholdMs: 触发阈值,默认 250
    ///   - minGapMs: 最小间隔,默认 4000
    ///   - maxSamples: 最大次数,默认 30
    public init(stallThresholdMs: Int = 250, minGapMs: Int = 4000, maxSamples: Int = 30) {
        self.stallThresholdMs = max(stallThresholdMs, 50)
        self.minGapMs = max(minGapMs, 0)
        self.maxSamples = max(maxSamples, 0)
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

/// `sample` 输出解析:提取主线程调用图中「采样数最多」的那条路径。
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

/// 卡顿栈采样器(进程内单例):由 `MainThreadHitchMonitor` 在检测到停滞时调用。
public final class HitchStackSampler: @unchecked Sendable {
    public static let shared = HitchStackSampler()

    private struct State {
        var taken = 0
        var lastAt: ContinuousClock.Instant?
        var running = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "oma.hitch-sampler", qos: .utility)
    /// 采样节流策略
    public let policy: HitchSamplePolicy

    /// - Parameter policy: 节流策略
    public init(policy: HitchSamplePolicy = HitchSamplePolicy()) { self.policy = policy }

    /// 是否启用:显式 `OMA_HITCH_SAMPLE=1`,或开发版 / 演示模式默认启用(`OMA_HITCH_SAMPLE=0` 可关闭)。
    /// - Parameter environment: 环境变量(测试可注入)
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let flag = environment["OMA_HITCH_SAMPLE"] { return flag == "1" }
        return AppEnv.isDev(environment: environment) || environment["OMA_DEMO"] == "1"
    }

    /// 主线程已停滞 `stalledMs` 毫秒:满足节流条件时在后台抓取一次栈。
    /// - Parameter stalledMs: 已停滞毫秒数
    public func stallDetected(stalledMs: Int) {
        let now = ContinuousClock.now
        let accepted = state.withLock { value -> Bool in
            let since = value.lastAt.map { Int(OMLogger.milliseconds(since: $0)) }
            guard !value.running, policy.shouldSample(stalledMs: stalledMs, sinceLastMs: since, taken: value.taken) else { return false }
            value.running = true
            value.taken += 1
            value.lastAt = now
            return true
        }
        guard accepted else { return }
        let sequence = state.withLock { $0.taken }
        queue.async { [self] in capture(stalledMs: stalledMs, sequence: sequence) }
    }

    /// 调用 `/usr/bin/sample` 抓取 1 秒栈(10ms 间隔),解析并落日志。
    private func capture(stalledMs: Int, sequence: Int) {
        defer { state.withLock { $0.running = false } }
        let directory = AppEnv.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = directory.appendingPathComponent("hitch-\(pid)-\(sequence).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(pid)", "1", "10", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.perf.warning("卡顿栈采样失败", ["error": "\(error)"])
            return
        }
        guard let data = try? Data(contentsOf: file) else { return }
        let path = HitchSampleParser.heaviestMainPath(in: String(decoding: data, as: UTF8.self))
        Log.perf.warning("卡顿栈", ["stalledMs": "\(stalledMs)", "file": file.lastPathComponent, "top": path.joined(separator: " > ")])
        pruneOldSamples(in: directory, keeping: 20)
    }

    /// 只保留最近的若干采样文件。
    private func pruneOldSamples(in directory: URL, keeping limit: Int) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let samples = urls.filter { $0.lastPathComponent.hasPrefix("hitch-") && $0.pathExtension == "txt" }
        guard samples.count > limit else { return }
        let sorted = samples.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(samples.count - limit) { try? FileManager.default.removeItem(at: url) }
    }
}
