// @author ixxxxoooo
// 套餐用量与提示缓存(参考 BaoCode):
// - 套餐限额是账号级的,所有会话共用一份(`PlanUsageCenter`);来源有二:回复时 Claude Code 的 `rate_limit_event`
//   (适配器经 `usage_update._meta["_claude/rateLimit"]` 转发,utilization 为 0...1),
//   与打开面板时主动探测的 `get_usage`(与 `/usage` 同源,不调用模型,utilization 为 0...100)。
// - 提示缓存来自每轮 `session/prompt` 响应的 usage(只含主对话,不含子 Agent 与压缩)。

import ACPKit
import Foundation
import Observation
import OMLog

// MARK: - 提示缓存

/// 请求输入按提示缓存的处理方式拆分的 token 数。
public struct CacheTokens: Sendable, Hashable {
    /// 从缓存读取
    public var read: Int
    /// 写入缓存(供后续请求读取)
    public var written: Int
    /// 未缓存(最后一个缓存断点之后,或模型不支持缓存)
    public var uncached: Int

    public init(read: Int = 0, written: Int = 0, uncached: Int = 0) {
        self.read = read
        self.written = written
        self.uncached = uncached
    }

    /// 输入总量。
    public var total: Int { read + written + uncached }

    /// 命中率(0...1,没有输入时为 0)。
    public var hitRate: Double { total == 0 ? 0 : Double(read) / Double(total) }

    /// 命中率百分比(四舍五入)。
    public var hitPercent: Int { Int((hitRate * 100).rounded()) }

    /// 逐项相加。
    public static func + (lhs: CacheTokens, rhs: CacheTokens) -> CacheTokens {
        CacheTokens(read: lhs.read + rhs.read, written: lhs.written + rhs.written, uncached: lhs.uncached + rhs.uncached)
    }
}

/// 提示缓存统计:最近一轮与整段主对话。
public struct PromptCacheStats: Sendable, Hashable {
    /// 最近一轮
    public var last: CacheTokens
    /// 本会话所有轮次之和
    public var conversation: CacheTokens

    public init(last: CacheTokens, conversation: CacheTokens) {
        self.last = last
        self.conversation = conversation
    }

    /// 记入一轮用量。
    /// - Parameters:
    ///   - turn: 本轮 usage
    ///   - previous: 之前的统计(没有时为 nil)
    /// - Returns: 新统计;本轮没有任何缓存读写(模型或提供商不支持缓存)时沿用之前的统计
    public static func recording(_ turn: TurnUsage, onto previous: PromptCacheStats?) -> PromptCacheStats? {
        let tokens = CacheTokens(read: turn.cachedReadTokens, written: turn.cachedWriteTokens, uncached: turn.inputTokens)
        guard tokens.read + tokens.written > 0 else { return previous }
        return PromptCacheStats(last: tokens, conversation: (previous?.conversation ?? CacheTokens()) + tokens)
    }
}

// MARK: - 套餐限额

/// 一个限额窗口(如 5 小时、每周)。
public struct RateLimitWindow: Sendable, Hashable, Identifiable {
    /// 窗口类型(`five_hour`、`seven_day`、`model:<名称>` 等),同类窗口后到的替换先到的
    public var id: String
    /// 展示名称
    public var label: String
    /// 已用比例(0...1)
    public var utilization: Double
    /// 重置时间
    public var resetsAt: Date?

    public init(id: String, label: String, utilization: Double, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// 指定时刻的已用比例:已过重置时间视为重新开始(0),否则夹在 0...1。
    /// - Parameter now: 当前时间
    public func fraction(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(utilization, 0), 1)
    }
}

/// 获取套餐限额的状态。
public enum PlanLimitsState: Sendable, Hashable {
    /// 未在获取;或不适用(如使用 API Key)
    case idle
    /// 正在获取
    case checking
    /// 获取过但没拿到
    case unavailable
    /// 用户关闭了非必要流量,不主动获取(回复仍可能带回限额)
    case off
}

/// 套餐限额解析(纯逻辑)。
public enum PlanUsageParser {
    /// `get_usage` 里按类型给出的窗口(按展示顺序)。
    static let windowTypes = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    /// 窗口类型的展示名称(与 Claude Code 一致,保留英文)。
    /// - Parameter type: 窗口类型
    public static func label(for type: String) -> String {
        switch type {
        case "five_hour": return "5-hour limit"
        case "seven_day": return "Weekly limit"
        case "seven_day_opus": return "Weekly Opus limit"
        case "seven_day_sonnet": return "Weekly Sonnet limit"
        case "seven_day_overage_included": return "Weekly with extra usage"
        case "overage": return "Extra usage"
        default: return type
        }
    }

    /// 解析回复时的 `rate_limit_event`(`rate_limit_info`):整组窗口,或接近上限时的单个窗口。
    /// - Parameter info: `rate_limit_info`
    /// - Returns: 窗口(utilization 已是 0...1);没有可用数据时为空
    public static func windows(rateLimitInfo info: JSONValue) -> [RateLimitWindow] {
        func window(_ type: String, _ value: JSONValue) -> RateLimitWindow? {
            guard let utilization = value["utilization"]?.doubleValue else { return nil }
            let resets = value["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
            return RateLimitWindow(id: type, label: label(for: type), utilization: utilization, resetsAt: resets)
        }
        if let unified = info["unifiedWindows"]?.objectValue {
            return unified.keys.sorted { order($0) < order($1) }.compactMap { key in unified[key].flatMap { window(key, $0) } }
        }
        guard let type = info["rateLimitType"]?.stringValue else { return [] }
        return window(type, info).map { [$0] } ?? []
    }

    /// 解析 `get_usage` 的响应。
    /// - Parameter response: 控制请求的响应体
    /// - Returns: `nil` 表示响应里还没有限额(Claude Code 仍在获取,可稍后重试);
    ///   `[]` 表示限额不适用(如 API Key 账号);否则为窗口(utilization 已换算为 0...1)
    public static func windows(usageResponse response: JSONValue) -> [RateLimitWindow]? {
        if response["rate_limits_available"]?.boolValue == false { return [] }
        guard let limits = response["rate_limits"], limits.objectValue != nil else { return nil }
        func window(_ id: String, _ label: String, _ value: JSONValue?) -> RateLimitWindow? {
            guard let value, let percent = value["utilization"]?.doubleValue else { return nil }
            let resets = value["resets_at"]?.stringValue.flatMap(parseDate)
            return RateLimitWindow(id: id, label: label, utilization: percent / 100, resetsAt: resets)
        }
        var result = windowTypes.compactMap { window($0, label(for: $0), limits[$0]) }
        for model in limits["model_scoped"]?.arrayValue ?? [] {
            guard let name = model["display_name"]?.stringValue else { continue }
            if let item = window("model:\(name)", "Weekly \(name) limit", model) { result.append(item) }
        }
        return result
    }

    /// 解析 ISO 8601 时间(兼容 6 位小数秒与 `+00:00` 时区)。
    /// - Parameter text: 时间文本
    /// - Returns: 时间;无法解析为 nil
    public static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        // 去掉小数秒再解析,并把小数部分补回(精度到毫秒足够)
        guard let dot = text.firstIndex(of: "."), dot > text.startIndex else { return nil }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let rest = text[text.index(after: dot)...].dropFirst(digits.count)
        guard let date = plain.date(from: String(text[..<dot]) + rest) else { return nil }
        return date.addingTimeInterval(Double("0." + digits) ?? 0)
    }

    /// 窗口类型的排序位次(已知类型在前,其余按名称)。
    private static func order(_ type: String) -> String {
        windowTypes.firstIndex(of: type).map { "0\($0)" } ?? "1\(type)"
    }
}

/// 「多久后重置」文案。
public enum PlanResetText {
    /// 距重置的剩余时间文案,如「46分钟后重置」「1小时30分钟后重置」「5天10小时后重置」。
    /// - Parameters:
    ///   - date: 重置时间
    ///   - now: 当前时间
    /// - Returns: 文案;已过重置时间为 nil
    public static func text(until date: Date, now: Date = Date()) -> String? {
        guard date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 60 { return ChatL10n.f("%lld分钟后重置", minutes) }
        let hours = minutes / 60
        if hours < 24 {
            return minutes % 60 == 0 ? ChatL10n.f("%lld小时后重置", hours) : ChatL10n.f("%lld小时%lld分钟后重置", hours, minutes % 60)
        }
        return hours % 24 == 0 ? ChatL10n.f("%lld天后重置", hours / 24) : ChatL10n.f("%lld天%lld小时后重置", hours / 24, hours % 24)
    }
}

/// 套餐用量中心(账号级,所有会话共用)。
@MainActor
@Observable
public final class PlanUsageCenter {
    public static let shared = PlanUsageCenter()

    /// 已知的限额窗口(按首次出现顺序)
    public private(set) var windows: [RateLimitWindow] = []
    /// 获取状态
    public private(set) var state: PlanLimitsState = .idle
    /// 使状态为 `.off` 的环境变量名
    public private(set) var offBy: String?

    /// 主动获取的结果:窗口(可能为空,表示不适用)、或没拿到(`nil`)。
    public typealias Fetcher = @Sendable () async -> [RateLimitWindow]?

    /// 两次主动获取的最小间隔。
    private let freshFor: Duration
    @ObservationIgnored private var fetchedAt: ContinuousClock.Instant?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    private let log = Log.agent

    /// - Parameter freshFor: 两次主动获取的最小间隔(测试可传 0)
    public init(freshFor: Duration = .seconds(30)) {
        self.freshFor = freshFor
    }

    /// 合入一组窗口:同类型替换,新类型追加。
    /// - Parameter fresh: 新窗口
    public func merge(_ fresh: [RateLimitWindow]) {
        guard !fresh.isEmpty else { return }
        var pending = fresh
        var merged = windows.map { old in
            guard let index = pending.firstIndex(where: { $0.id == old.id }) else { return old }
            return pending.remove(at: index)
        }
        merged.append(contentsOf: pending)
        windows = merged
    }

    /// 合入回复时的 `rate_limit_event`。
    /// - Parameter info: `rate_limit_info`
    public func apply(rateLimitInfo info: JSONValue) {
        merge(PlanUsageParser.windows(rateLimitInfo: info))
    }

    /// 主动获取一次限额(30 秒内只取一次,并发调用合并为一次)。
    /// - Parameters:
    ///   - offBy: 关闭主动获取的环境变量名(为 nil 时正常获取)
    ///   - fetcher: 获取方法
    public func refresh(offBy: String?, fetcher: @escaping Fetcher) async {
        if let offBy {
            self.offBy = offBy
            state = .off
            return
        }
        if let fetchedAt, ContinuousClock.now - fetchedAt < freshFor { return }
        if let inflight { return await inflight.value }
        let started = ContinuousClock.now
        state = .checking
        let task = Task { @MainActor [weak self] in
            let result = await fetcher()
            guard let self else { return }
            if let result {
                self.fetchedAt = .now
                self.merge(result)
                self.state = .idle
                self.log.info("套餐用量已刷新", ["windows": "\(result.count)", "ms": "\(OMLogger.milliseconds(since: started))"])
            } else {
                self.state = .unavailable
                self.log.warning("套餐用量获取失败", ["ms": "\(OMLogger.milliseconds(since: started))"])
            }
        }
        inflight = task
        await task.value
        inflight = nil
    }
}
