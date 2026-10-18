// @author ixxxxoooo
// 客户端级会话选项:网络代理/超时、追加系统提示词、是否加载 CLAUDE.md。
// 这些选项在创建/恢复会话时合并进 ACP `_meta`(`claudeCode.options.env` 与 `systemPrompt.append`)。

import ACPKit
import Foundation

/// 网络代理模式。
public enum ProxyMode: String, CaseIterable, Sendable, Identifiable {
    /// 沿用系统/登录 shell 环境(不注入任何变量)
    case system
    /// 强制直连(清空代理变量)
    case off
    case http
    case socks5

    public var id: String { rawValue }
}

/// 发送键。
public enum SendKey: String, Sendable, CaseIterable, Identifiable {
    /// Return 发送,Shift+Return 换行
    case enter
    /// ⌘Return 发送,Return 换行
    case commandEnter

    public var id: String { rawValue }
}

/// Agent 运行中再发送消息的默认行为。
public enum RunningSendMode: String, Sendable, CaseIterable, Identifiable {
    /// 作为引导注入当前轮次(Agent 不支持时排队)
    case steer
    /// 排到本轮结束后发送
    case queue

    public var id: String { rawValue }
}

/// 聊天内容宽度档位。`custom` 使用 `chat.widthCustom`(点数)。
public enum ChatWidth: String, Sendable, CaseIterable, Identifiable {
    case compact, narrow, standard, comfortable, wide, ultra, full, custom

    public var id: String { rawValue }

    /// 自定义宽度的范围与步长(点)。
    public static let customRange: ClosedRange<Double> = 480...1600
    public static let customStep: Double = 20
    public static let customDefault: Double = 900

    /// 滑块使用的预设档位(从窄到宽,不含自定义)。
    public static var presets: [ChatWidth] { allCases.filter { $0 != .custom } }

    /// 该宽度在滑块上对应的档位下标:自定义宽度吸附到点数最接近的预设。
    /// - Parameters:
    ///   - raw: `chat.width` 存储的档位原始值
    ///   - custom: `chat.widthCustom` 存储的自定义点数
    /// - Returns: `presets` 中的下标
    public static func presetIndex(raw: String, custom: Double) -> Int {
        let presets = Self.presets
        let width = ChatWidth(rawValue: raw) ?? .standard
        if width != .custom { return presets.firstIndex(of: width) ?? 0 }
        let target = CGFloat(clampedCustom(custom))
        let finite = presets.enumerated().filter { $0.element.points.isFinite }
        return finite.min { abs($0.element.points - target) < abs($1.element.points - target) }?.offset ?? 0
    }

    /// 预设档位的最大宽度(点);`full` 为不限制;`custom` 取默认自定义值。
    public var points: CGFloat {
        switch self {
        case .compact: return 560
        case .narrow: return 680
        case .standard: return 820
        case .comfortable: return 920
        case .wide: return 1000
        case .ultra: return 1200
        case .full: return .infinity
        case .custom: return CGFloat(Self.customDefault)
        }
    }

    /// 由持久化值解析最终宽度:未知回退标准档;自定义值夹到范围内并对齐步长。
    /// - Parameters:
    ///   - raw: `chat.width` 存储的档位原始值
    ///   - custom: `chat.widthCustom` 存储的自定义点数
    /// - Returns: 最大宽度(点)
    public static func resolve(raw: String, custom: Double) -> CGFloat {
        let width = ChatWidth(rawValue: raw) ?? .standard
        guard width == .custom else { return width.points }
        return CGFloat(clampedCustom(custom))
    }

    /// 把自定义宽度夹到范围并对齐步长;非有限值回退默认。
    public static func clampedCustom(_ value: Double) -> Double {
        guard value.isFinite else { return customDefault }
        let clamped = min(max(value, customRange.lowerBound), customRange.upperBound)
        return (clamped / customStep).rounded() * customStep
    }

    /// 设置页显示的档位名。
    public var displayName: String {
        switch self {
        case .compact: return String(localized: "紧凑")
        case .narrow: return String(localized: "较窄")
        case .standard: return String(localized: "标准")
        case .comfortable: return String(localized: "较宽")
        case .wide: return String(localized: "宽")
        case .ultra: return String(localized: "超宽")
        case .full: return String(localized: "铺满")
        case .custom: return String(localized: "自定义")
        }
    }
}

/// MCP 工具按需加载模式(对应 Claude Code 的 `ENABLE_TOOL_SEARCH`)。
///
/// 开启后 MCP 工具定义不再一次性塞进上下文,而是由模型按需搜索加载,可显著降低启动占用。
/// Claude Code 默认只在直连官方 API 且 MCP 工具超过窗口 10% 时才自动启用;经第三方网关(自定义 `ANTHROPIC_BASE_URL`)时默认关闭。
public enum McpToolSearch: String, Sendable, CaseIterable, Identifiable {
    /// 保持 Claude Code 默认行为(不注入变量)
    case auto
    /// 强制开启(`ENABLE_TOOL_SEARCH=true`):第三方网关需支持 tool_reference,否则可能报错
    case on
    /// 强制关闭(`ENABLE_TOOL_SEARCH=false`):所有 MCP 工具定义启动即加载
    case off

    public var id: String { rawValue }

    /// 注入进程的环境变量值;`auto` 不注入。
    public var environmentValue: String? {
        switch self {
        case .auto: return nil
        case .on: return "true"
        case .off: return "false"
        }
    }

    /// 设置页显示名。
    public var displayName: String {
        switch self {
        case .auto: return String(localized: "自动(默认)")
        case .on: return String(localized: "始终按需加载")
        case .off: return String(localized: "启动时全部加载")
        }
    }
}

/// 设置页内容宽度档位(所有设置页统一使用,外观页可配置)。`custom` 使用 `settings.widthCustom`(点数)。
public enum SettingsContentWidth: String, Sendable, CaseIterable, Identifiable {
    case compact, standard, wide, full, custom

    public var id: String { rawValue }

    /// 自定义宽度的范围与步长(点)。
    public static let customRange: ClosedRange<Double> = 560...1600
    public static let customStep: Double = 20
    public static let customDefault: Double = 900

    /// 滑块使用的预设档位(从窄到宽,不含自定义)。
    public static var presets: [SettingsContentWidth] { allCases.filter { $0 != .custom } }

    /// 该宽度在滑块上对应的档位下标:自定义宽度吸附到点数最接近的预设。
    /// - Parameters:
    ///   - raw: `settings.width` 存储的档位原始值
    ///   - custom: `settings.widthCustom` 存储的自定义点数
    /// - Returns: `presets` 中的下标
    public static func presetIndex(raw: String, custom: Double) -> Int {
        let presets = Self.presets
        let width = SettingsContentWidth(rawValue: raw) ?? .standard
        if width != .custom { return presets.firstIndex(of: width) ?? 0 }
        let target = CGFloat(clampedCustom(custom))
        let finite = presets.enumerated().filter { $0.element.points.isFinite }
        return finite.min { abs($0.element.points - target) < abs($1.element.points - target) }?.offset ?? 0
    }

    /// 预设档位的最大宽度(点);`full` 为不限制;`custom` 取默认自定义值。
    public var points: CGFloat {
        switch self {
        case .compact: return 680
        case .standard: return 860
        case .wide: return 1040
        case .full: return .infinity
        case .custom: return CGFloat(Self.customDefault)
        }
    }

    /// 由持久化值解析最终宽度:未知回退标准档;自定义值夹到范围内并对齐步长。
    /// - Parameters:
    ///   - raw: `settings.width` 存储的档位原始值
    ///   - custom: `settings.widthCustom` 存储的自定义点数
    /// - Returns: 最大宽度(点)
    public static func resolve(raw: String, custom: Double) -> CGFloat {
        let width = SettingsContentWidth(rawValue: raw) ?? .standard
        guard width == .custom else { return width.points }
        return CGFloat(clampedCustom(custom))
    }

    /// 把自定义宽度夹到范围并对齐步长;非有限值回退默认。
    public static func clampedCustom(_ value: Double) -> Double {
        guard value.isFinite else { return customDefault }
        let clamped = min(max(value, customRange.lowerBound), customRange.upperBound)
        return (clamped / customStep).rounded() * customStep
    }

    /// 外观页显示的档位名。
    public var displayName: String {
        switch self {
        case .compact: return String(localized: "紧凑")
        case .standard: return String(localized: "标准")
        case .wide: return String(localized: "宽")
        case .full: return String(localized: "铺满")
        case .custom: return String(localized: "自定义")
        }
    }
}

/// 一次会话创建所需的客户端选项快照。
public struct SessionOptions: Equatable, Sendable {
    public var proxyMode: ProxyMode = .system
    /// 代理地址 `host:port`(`http`/`socks5` 模式使用)
    public var proxyAddress = ""
    /// 请求超时(秒);0 表示使用 Claude Code 默认值
    public var timeoutSeconds = 0
    /// 追加到系统提示词末尾的文本
    public var appendPrompt = ""
    /// 是否加载 CLAUDE.md(记忆文件)
    public var loadClaudeMemory = true
    /// MCP 工具按需加载模式
    public var mcpToolSearch = McpToolSearch.auto
    /// 自动压缩窗口(token):对话占用达到该窗口的压缩阈值就压缩,给上下文设上限;0 表示使用 Claude Code / 模型默认值
    public var autoCompactWindow = 0

    /// 自动压缩窗口允许的范围(token);Claude Code 的上限是 100 万。
    public static let autoCompactRange = 50_000...1_000_000
    /// 自动压缩窗口对应的环境变量。
    public static let autoCompactKey = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"

    public init() {}

    /// 从偏好读取当前选项。
    /// - Parameter defaults: 偏好存储
    public init(defaults: UserDefaults) {
        proxyMode = ProxyMode(rawValue: defaults.string(forKey: ClientPrefs.Key.proxyMode) ?? "") ?? .system
        proxyAddress = defaults.string(forKey: ClientPrefs.Key.proxyAddress) ?? ""
        timeoutSeconds = max(defaults.integer(forKey: ClientPrefs.Key.requestTimeout), 0)
        appendPrompt = defaults.string(forKey: ClientPrefs.Key.appendPrompt) ?? ""
        loadClaudeMemory = defaults.object(forKey: ClientPrefs.Key.loadClaudeMemory) as? Bool ?? true
        mcpToolSearch = McpToolSearch(rawValue: defaults.string(forKey: ClientPrefs.Key.mcpToolSearch) ?? "") ?? .auto
        autoCompactWindow = max(defaults.integer(forKey: ClientPrefs.Key.autoCompactWindow), 0)
    }

    /// 夹到允许范围后的自动压缩窗口;未设置(≤ 0)返回 nil。
    public var effectiveAutoCompactWindow: Int? {
        guard autoCompactWindow > 0 else { return nil }
        return min(max(autoCompactWindow, Self.autoCompactRange.lowerBound), Self.autoCompactRange.upperBound)
    }

    /// 规范化后的代理 URL;模式为 `system`/`off` 或地址无效时返回 nil。
    public var proxyURL: String? {
        let address = proxyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, proxyMode == .http || proxyMode == .socks5 else { return nil }
        let scheme = proxyMode == .socks5 ? "socks5" : "http"
        if address.contains("://") { return address }
        return "\(scheme)://\(address)"
    }

    /// 需要注入 Claude 进程的环境变量。
    public var environment: [String: String] {
        var env: [String: String] = [:]
        switch proxyMode {
        case .system:
            break
        case .off:
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { env[name] = "" }
            env["NO_PROXY"] = "*"
        case .http, .socks5:
            if let url = proxyURL {
                if proxyMode == .http {
                    for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { env[name] = url }
                } else {
                    env["ALL_PROXY"] = url
                    env["all_proxy"] = url
                }
            }
        }
        if timeoutSeconds > 0 { env["API_TIMEOUT_MS"] = String(timeoutSeconds * 1000) }
        if !loadClaudeMemory { env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1" }
        if let value = mcpToolSearch.environmentValue { env["ENABLE_TOOL_SEARCH"] = value }
        if let window = effectiveAutoCompactWindow { env[Self.autoCompactKey] = String(window) }
        return env
    }

    /// 追加提示词(去除首尾空白;为空返回 nil)。
    public var trimmedPrompt: String? {
        let text = appendPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 是否有任何选项需要写入 `_meta`。
    public var isDefault: Bool { environment.isEmpty && trimmedPrompt == nil }

    /// 把选项合并进已有的会话 `_meta`(如模型提供商生成的),不覆盖提供商已设置的变量。
    /// - Parameter base: 已有 `_meta`(可为 nil)
    /// - Returns: 合并后的 `_meta`;无任何选项且 `base` 为 nil 时返回 nil
    public func merged(into base: JSONValue?) -> JSONValue? {
        guard !isDefault else { return base }
        var root: [String: JSONValue] = [:]
        if case .object(let object)? = base { root = object }

        var claudeCode: [String: JSONValue] = [:]
        if case .object(let object)? = root["claudeCode"] { claudeCode = object }
        var options: [String: JSONValue] = [:]
        if case .object(let object)? = claudeCode["options"] { options = object }
        var env: [String: JSONValue] = [:]
        if case .object(let object)? = options["env"] { env = object }
        // 提供商/用户已显式设置的变量优先
        for (key, value) in environment where env[key] == nil { env[key] = .string(value) }
        // 模型映射在 settings.env 里也给了窗口时取较小值:全局上限不被映射的大窗口覆盖
        if let window = effectiveAutoCompactWindow, case .object(var settings)? = options["settings"],
           case .object(var settingsEnv)? = settings["env"],
           let mapped = settingsEnv[Self.autoCompactKey]?.stringValue.flatMap({ Int($0) }) {
            settingsEnv[Self.autoCompactKey] = .string(String(min(mapped, window)))
            settings["env"] = .object(settingsEnv)
            options["settings"] = .object(settings)
            env.removeValue(forKey: Self.autoCompactKey)
        }
        if !env.isEmpty { options["env"] = .object(env) }
        if !options.isEmpty { claudeCode["options"] = .object(options) }
        if !claudeCode.isEmpty { root["claudeCode"] = .object(claudeCode) }

        if let prompt = trimmedPrompt, root["systemPrompt"] == nil {
            root["systemPrompt"] = .object(["append": .string(prompt)])
        }
        return .object(root)
    }
}
