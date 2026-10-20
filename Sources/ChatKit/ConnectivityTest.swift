// @author ixxxxoooo
// 网络连通性测试:对一组常用站点各发一次 HEAD 请求并计时(收到任何 HTTP 响应即视为可访问)。
// 探测函数可注入,测试不依赖真实网络。

import Foundation

/// 连通性测试目标。
public struct ConnectivityTarget: Sendable, Equatable, Identifiable {
    public var id: String { host }
    /// 显示名称
    public let name: String
    /// 主机名
    public let host: String
    /// 图标名(`Image.om` 可识别)
    public let icon: String

    /// - Parameters:
    ///   - name: 显示名称
    ///   - host: 主机名(不含协议)
    ///   - icon: 图标名
    public init(name: String, host: String, icon: String) {
        self.name = name
        self.host = host
        self.icon = icon
    }

    /// 默认测试站点。
    public static let defaults: [ConnectivityTarget] = [
        ConnectivityTarget(name: "Google", host: "www.google.com", icon: "brand.google"),
        ConnectivityTarget(name: "YouTube", host: "www.youtube.com", icon: "circle-play"),
        ConnectivityTarget(name: "Anthropic", host: "api.anthropic.com", icon: "brand.anthropic"),
        ConnectivityTarget(name: "OpenAI", host: "api.openai.com", icon: "brand.openai"),
        ConnectivityTarget(name: "Baidu", host: "www.baidu.com", icon: "brand.baidu"),
    ]
}

/// 单个站点的测试结果。
public enum ConnectivityResult: Sendable, Equatable {
    /// 测试中
    case testing
    /// 可访问,附耗时(毫秒)
    case reachable(milliseconds: Int)
    /// 不可访问,附原因
    case failed(String)
}

/// 探测函数:对主机发起一次请求,成功返回耗时毫秒,失败抛错。
public typealias ConnectivityProbe = @Sendable (_ host: String) async throws -> Int

public enum ConnectivityTest {
    /// 真实探测:HTTPS HEAD,8 秒超时,不使用缓存与 Cookie;任何 HTTP 状态码都算连通。
    /// - Parameter host: 主机名
    /// - Returns: 耗时(毫秒)
    public static let urlSessionProbe: ConnectivityProbe = { host in
        guard let url = URL(string: "https://\(host)/") else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieStorage = nil
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let start = ContinuousClock.now
        _ = try await URLSession(configuration: config).data(for: request)
        let elapsed = ContinuousClock.now - start
        let parts = elapsed.components
        return max(1, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }

    /// 并发测试全部目标。
    /// - Parameters:
    ///   - targets: 测试目标
    ///   - probe: 探测函数
    ///   - onResult: 每个目标出结果时回调(目标 id、结果)
    public static func run(
        _ targets: [ConnectivityTarget],
        probe: @escaping ConnectivityProbe = urlSessionProbe,
        onResult: @escaping @Sendable (String, ConnectivityResult) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let ms = try await probe(target.host)
                        await onResult(target.id, .reachable(milliseconds: ms))
                    } catch {
                        await onResult(target.id, .failed((error as? URLError)?.localizedDescription ?? error.localizedDescription))
                    }
                }
            }
        }
    }
}
