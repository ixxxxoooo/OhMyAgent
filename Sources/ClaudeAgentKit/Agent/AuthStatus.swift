// @author ixxxxoooo
// 鉴权身份上报(`_auth/status_update` 扩展):告知客户端 Agent 进程自身用的是哪种身份
// (Claude 订阅、API Key、网关、外部云凭据或未登录)。只推送、不提供查询接口。

import ACPKit
import Foundation
import OMLog

/// 身份快照。
public struct AuthStatus: Sendable, Equatable {
    /// 订阅账号信息
    public struct Account: Sendable, Equatable {
        public var plan: String?
        public var email: String?
        public var organization: String?
    }

    /// `account` / `api_key` / `gateway` / `external` / `none`
    public var kind: String
    public var label: String
    public var detail: String?
    public var account: Account?

    /// 未登录。
    public static let notLoggedIn = AuthStatus(kind: "none", label: "Not logged in")

    /// 序列化为 ACP 载荷。
    public var json: JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind), "label": .string(label)]
        if let detail { object["detail"] = .string(detail) }
        if let account {
            var fields: [String: JSONValue] = [:]
            if let plan = account.plan { fields["plan"] = .string(plan) }
            if let email = account.email { fields["email"] = .string(email) }
            if let organization = account.organization { fields["organization"] = .string(organization) }
            object["account"] = .object(fields)
        }
        return .object(object)
    }

    /// 网关鉴权(ACP 层 `authenticate`)。
    /// - Parameter baseUrl: 网关地址;只上报主机名
    public static func gateway(baseUrl: String? = nil) -> AuthStatus {
        var status = AuthStatus(kind: "gateway", label: "Custom model gateway")
        if let baseUrl, !baseUrl.isEmpty { status.detail = URL(string: baseUrl)?.host(percentEncoded: false) ?? baseUrl }
        return status
    }

    private static let keySourceDetails: [String: String] = [
        "apiKeyHelper": "API key helper", "env": "env", "ANTHROPIC_API_KEY": "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN": "ANTHROPIC_AUTH_TOKEN",
    ]
    private static let externalLabels: [String: String] = [
        "bedrock": "AWS Bedrock", "vertex": "Google Vertex AI", "foundry": "Azure AI Foundry", "anthropicAws": "Anthropic on AWS",
        "anthropicGoogleCloud": "Anthropic on Google Cloud", "mantle": "Mantle",
    ]

    /// 会话 `account` 是否带有可用的身份信号(空读取不能被当作「已登出」)。
    static func accountHasIdentitySignal(_ account: JSONValue?) -> Bool {
        guard let account else { return false }
        if account["apiKeySource"]?.nonEmptyString != nil || account["subscriptionType"]?.nonEmptyString != nil { return true }
        if let provider = account["apiProvider"]?.nonEmptyString, provider != "firstParty" { return true }
        return false
    }

    /// 由 CLI 初始化响应里的 `account` 映射;无身份信号时返回 nil。
    static func from(account: JSONValue?) -> AuthStatus? {
        guard let account, accountHasIdentitySignal(account) else { return nil }
        return map(provider: account["apiProvider"]?.stringValue, subscription: account["subscriptionType"]?.stringValue,
                   keySource: account["apiKeySource"]?.stringValue, email: account["email"]?.stringValue,
                   organization: account["organization"]?.stringValue)
    }

    /// 由 `claude auth status --json` 的输出映射;不是预期 JSON 时返回 nil。
    static func from(cliOutput: String) -> AuthStatus? {
        guard let data = cliOutput.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              value.objectValue != nil, let loggedIn = value["loggedIn"]?.boolValue else { return nil }
        let provider = value["apiProvider"]?.nonEmptyString
        let external = provider != nil && provider != "firstParty"
        if !external, !loggedIn, value["apiKeySource"]?.nonEmptyString == nil { return .notLoggedIn }
        return map(provider: provider, subscription: value["subscriptionType"]?.stringValue, keySource: value["apiKeySource"]?.stringValue,
                   email: value["email"]?.stringValue, organization: value["orgName"]?.stringValue)
    }

    private static func map(provider: String?, subscription: String?, keySource: String?, email: String?, organization: String?) -> AuthStatus {
        if provider == "gateway" { return .gateway() }
        if let provider, !provider.isEmpty, provider != "firstParty" {
            return AuthStatus(kind: "external", label: externalLabels[provider] ?? provider)
        }
        if let keySource, !keySource.isEmpty {
            return AuthStatus(kind: "api_key", label: "Anthropic API key", detail: keySourceDetails[keySource])
        }
        if let subscription, !subscription.isEmpty {
            return AuthStatus(kind: "account", label: planLabel(subscription),
                              account: Account(plan: subscription, email: email?.nonEmpty, organization: organization?.nonEmpty))
        }
        return .notLoggedIn
    }

    /// 只带一个「Claude」前缀、每个词首字母大写:`max` 与 `Claude Max` 都显示为 `Claude Max`。
    static func planLabel(_ plan: String) -> String {
        let titled = plan.split(separator: " ", omittingEmptySubsequences: true).map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
        return plan.lowercased().hasPrefix("claude") ? titled : "Claude \(titled)"
    }

    /// 是否同一个登录(按各类型的标识字段比较)。
    func sameIdentity(as other: AuthStatus) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case "api_key": return detail == other.detail
        case "account": return (account?.email ?? "") == (other.account?.email ?? "")
        default: return true
        }
    }

    /// 把新读数并入已知状态:同一登录时逐字段以新值为准、缺失字段沿用旧值;不同登录整体替换。
    func merged(into previous: AuthStatus?) -> AuthStatus {
        guard let previous, previous.sameIdentity(as: self) else { return self }
        var merged = self
        if merged.detail == nil { merged.detail = previous.detail }
        if previous.account != nil || account != nil {
            merged.account = Account(plan: account?.plan ?? previous.account?.plan, email: account?.email ?? previous.account?.email,
                                     organization: account?.organization ?? previous.account?.organization)
        }
        return merged
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// 身份上报中心:保存当前身份、探测 CLI、仅在内容变化时推送。
actor AuthStatusCenter {
    static let method = "_auth/status_update"
    /// 单次 `claude auth status --json` 的上限(秒)
    static let probeTimeout: TimeInterval = 5

    private let config: ClaudeAgentConfig
    private let link: any AgentClientLink
    private let log = Log.agent.with(["part": "auth-status"])
    private(set) var current: AuthStatus?
    private var epoch = 0
    private var inflight: Task<AuthStatus?, Never>?
    private var gatewayActive = false
    private var loggedTimeout = false

    init(config: ClaudeAgentConfig, link: any AgentClientLink) {
        self.config = config
        self.link = link
    }

    /// 与已知状态不同才推送。
    func set(_ next: AuthStatus?) {
        guard let next, next != current else { return }
        current = next
        let payload: JSONValue = ["authStatus": next.json]
        Task { [link] in await link.notify(Self.method, payload) }
    }

    /// ACP 层网关鉴权完成:网关持有凭据,优先于 CLI 读数。
    func gatewayAuthenticated(baseUrl: String? = nil) {
        gatewayActive = true
        epoch += 1
        set(.gateway(baseUrl: baseUrl))
    }

    /// 会话创建后用其 `account` 上报(信息最全);无身份信号则保留探测结果。
    func publish(sessionAccount: JSONValue?) {
        guard !gatewayActive else { return }
        if let status = AuthStatus.from(account: sessionAccount) { set(status) }
    }

    /// 登出后读数必须在清除凭据之后开始;读不到就退回「未登录」。
    func afterLogout() async {
        epoch += 1
        if await probe(fresh: true) == nil { set(.notLoggedIn) }
    }

    /// 后台读取一次(不等待);结果变化时推送。
    func probeInBackground() {
        Task { _ = await self.probe() }
    }

    /// 探测 CLI 身份。同时多次调用共享一次运行;`fresh` 强制新开。
    @discardableResult
    func probe(fresh: Bool = false) async -> AuthStatus? {
        if !fresh, let inflight { return await inflight.value }
        let startEpoch = epoch
        let task = Task { await self.runProbe(startEpoch: startEpoch) }
        inflight = task
        let result = await task.value
        inflight = nil
        return result
    }

    private func runProbe(startEpoch: Int) async -> AuthStatus? {
        if gatewayActive { return current }
        let result: CLIRunResult
        do {
            result = try await CLIRunner.run(executable: config.executable, arguments: ["auth", "status", "--json"],
                                             environment: config.environment, timeout: Self.probeTimeout)
        } catch CLIRunError.timedOut {
            if !loggedTimeout {
                loggedTimeout = true
                log.error("claude auth status 5 秒内无响应,身份不刷新")
            }
            return current
        } catch {
            log.error("claude auth status 失败", error: error)
            return nil
        }
        // 未登录时退出码为 1 但仍输出合法 JSON,故成败都解析 stdout
        guard let status = AuthStatus.from(cliOutput: result.stdout) else {
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || result.status == 0 { log.error("claude auth status 输出无法解析") }
            return nil
        }
        guard startEpoch == epoch else {
            log.info("丢弃早于最近一次鉴权变化的探测结果")
            return current
        }
        let merged = status.merged(into: current)
        set(merged)
        return merged
    }
}
