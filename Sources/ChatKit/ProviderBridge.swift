// @author ixxxxoooo
// 提供商 → 会话的桥接:OpenAI 协议的提供商经本地协议代理接入 Claude Code。
//
// 代理持有真实的上游地址与密钥;Claude Code 只拿到本地代理地址和一个占位令牌,
// 因此真实密钥不会进入 Claude Code 子进程的环境变量。

import Foundation
import OMLog
import ProviderProxyKit

/// 提供商桥接。
public enum ProviderBridge {
    /// 交给 Claude Code 的占位令牌(代理不校验,真实密钥在代理内存里)。
    public static let placeholderToken = "oma-local-proxy"

    /// 本次进程内稳定的 OpenCode 会话标识。
    private static let opencodeSession = "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

    /// OpenCode 兼容请求头(尽力模拟其官方客户端;免费层可能仍拒绝第三方)。
    /// - Returns: 请求头字典
    public static func opencodeHeaders() -> [String: String] {
        [
            "User-Agent": "opencode/1.0.0",
            "x-opencode-client": "cli",
            "x-opencode-session": opencodeSession,
            "x-opencode-request": "req_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))",
            "x-opencode-project": "global",
        ]
    }

    /// 为 OpenAI 协议的提供商构造代理路由。
    /// - Parameters:
    ///   - provider: 提供商
    ///   - key: 密钥(可空)
    /// - Returns: 路由;地址无效返回 nil
    public static func route(for provider: ModelProvider, key: String) -> ProxyRoute? {
        guard let url = provider.url else { return nil }
        var headers: [String: String] = [:]
        if provider.opencodeCompat == true { headers.merge(opencodeHeaders()) { _, new in new } }
        for line in ModelProvider.headerLines(provider.customHeaders ?? "") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return ProxyRoute(upstreamBase: url, apiKey: key, extraHeaders: headers)
    }

    /// 把解析后的提供商变成可启动会话的形态:OpenAI 协议注册到代理并改写 `_meta`;Anthropic 协议原样返回。
    /// - Parameters:
    ///   - resolved: 解析结果
    ///   - proxy: 协议代理(测试可注入)
    /// - Returns: 可直接用于会话启动的结果
    /// - Throws: 代理启动失败或地址无效
    public static func activate(_ resolved: ResolvedProvider, proxy: ProviderProxy = .shared) async throws -> ResolvedProvider {
        let provider = resolved.provider
        guard provider.isOpenAIProtocol else { return resolved }
        guard let route = route(for: provider, key: resolved.key) else { throw ModelProvider.ValidationError.invalidBaseURL }
        let local = try await proxy.register(key: provider.id, route: route)
        var proxied = provider
        proxied.baseURL = local.absoluteString
        proxied.protocolKind = nil
        proxied.usesAPIKeyHeader = nil
        proxied.customHeaders = nil
        var result = resolved
        result.meta = ProviderLaunch.sessionMeta(proxied, key: placeholderToken)
        return result
    }
}
