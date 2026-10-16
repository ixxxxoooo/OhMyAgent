// @author ixxxxoooo
// 模型网关(代理)可达性:解析 `~/.claude/settings.json` / 进程环境里配置的 `ANTHROPIC_BASE_URL`,
// 发送前探测其是否可连接,并把失败翻译成可操作的中文提示。
//
// 背景:Claude Code 通过 `ANTHROPIC_BASE_URL` 走 Claude Code Router 等本地代理时,代理没启动会让
// SDK 静默重试 10 余次(每次 "Connection error"),界面上只看到长时间无响应,最终显示"请求已取消"。

import Foundation
import OMLog

/// 网关探测结果。
public enum GatewayStatus: Equatable, Sendable {
    /// 未配置自定义网关(直连官方 API 或由 claude 自行处理)
    case notConfigured
    /// 可连接(收到任意 HTTP 响应即视为可达,鉴权/路径问题由上游报错)
    case reachable(URL)
    /// 不可连接
    case unreachable(URL, reason: String)
}

/// 模型网关解析与探测。
public enum ModelGateway {
    /// 解析网关地址:优先 `~/.claude/settings.json` 的 `env`(Claude Code 以它覆盖进程环境),其次进程环境。
    /// - Parameters:
    ///   - settingsEnv: settings.json 中的 env 字典
    ///   - processEnv: 进程环境
    /// - Returns: 合法的 http/https 地址;未配置返回 nil
    public static func baseURL(settingsEnv: [String: String], processEnv: [String: String]) -> URL? {
        for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_BASE_URL", "CLAUDE_AGENT_API_BASE_URL"] {
            for source in [settingsEnv, processEnv] {
                guard let raw = source[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { continue }
                return url
            }
        }
        return nil
    }

    /// 读取 `~/.claude/settings.json` 的 `env` 字典(失败返回空)。
    /// - Parameter home: 家目录(测试可注入)
    /// - Returns: 仅包含字符串值的环境字典
    public static func loadSettingsEnv(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        let file = home.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in env {
            if let text = value as? String { result[key] = text }
        }
        return result
    }

    /// 解析当前生效的网关地址(读磁盘,请在后台调用)。
    /// - Parameter processEnv: 进程环境
    /// - Returns: 网关地址
    public static func resolveBaseURL(processEnv: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        baseURL(settingsEnv: loadSettingsEnv(), processEnv: processEnv)
    }

    /// 探测网关是否可连接。收到任意 HTTP 响应即视为可达。
    /// - Parameters:
    ///   - url: 网关地址
    ///   - timeout: 超时秒数
    /// - Returns: 探测结果
    public static func probe(_ url: URL, timeout: TimeInterval = 2) async -> GatewayStatus {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: request)
            return .reachable(url)
        } catch let error as URLError {
            return .unreachable(url, reason: describe(error))
        } catch {
            return .unreachable(url, reason: error.localizedDescription)
        }
    }

    /// 解析并探测(磁盘读取与网络均在后台)。
    /// - Parameter timeout: 超时秒数
    /// - Returns: 探测结果
    public static func check(timeout: TimeInterval = 2) async -> GatewayStatus {
        let url = await Task.detached(priority: .userInitiated) { resolveBaseURL() }.value
        guard let url else { return .notConfigured }
        return await probe(url, timeout: timeout)
    }

    /// 把 `URLError` 翻译成中文原因。
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost: String(localized: "连接被拒绝(服务未启动?)")
        case .timedOut: String(localized: "连接超时")
        case .cannotFindHost, .dnsLookupFailed: String(localized: "域名无法解析")
        case .networkConnectionLost: String(localized: "连接被中断")
        case .notConnectedToInternet: String(localized: "当前没有网络")
        case .secureConnectionFailed, .serverCertificateUntrusted: String(localized: "TLS 握手失败")
        default: error.localizedDescription
        }
    }

    /// 网关不可达时展示给用户的提示。
    /// - Parameters:
    ///   - url: 网关地址
    ///   - reason: 失败原因
    /// - Returns: 中文提示(含处理建议)
    public static func unreachableMessage(url: URL, reason: String) -> String {
        let local = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
        let hint = local
            ? String(localized: "请先启动本地代理(如 Claude Code Router),或在 ~/.claude/settings.json 的 env 中修正 ANTHROPIC_BASE_URL。")
            : String(localized: "请检查网络与代理服务状态,或在 ~/.claude/settings.json 的 env 中修正 ANTHROPIC_BASE_URL。")
        return String(localized: "无法连接模型网关 \(origin(of: url)):\(reason)。\(hint)消息已放回输入框,恢复后再次发送即可。")
    }

    /// 取 `scheme://host:port` 形式(不含路径与凭据,避免泄露)。
    static func origin(of url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? "?"
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// 根据 Agent 的 stderr / 错误文本识别常见上游失败并给出提示。
    /// - Parameter text: 原始文本
    /// - Returns: 可操作提示;无法识别返回 nil
    public static func classify(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("connection error") || lower.contains("econnrefused") || lower.contains("fetch failed") {
            return String(localized: "模型请求连接失败:网关或网络不可用,请检查代理是否在运行。")
        }
        if lower.contains("unrecognized_model") || lower.contains("model_not_found") || lower.contains("no such model")
            || (lower.contains("model") && lower.contains("not found")) {
            return String(localized: "网关不认识当前模型:请在模型选择器中换一个可用模型,或检查 settings.json 里的 ANTHROPIC_MODEL。")
        }
        if lower.contains("401") || lower.contains("invalid api key") || lower.contains("authentication") {
            return String(localized: "网关鉴权失败:请检查 API Key(apiKeyHelper / ANTHROPIC_AUTH_TOKEN)是否有效。")
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return String(localized: "触发限流(429):请稍后重试,免费模型额度可能已用尽。")
        }
        if lower.contains("overloaded") || lower.contains("529") {
            return String(localized: "上游模型过载:请稍后重试。")
        }
        return nil
    }
}
