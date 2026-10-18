// @author ixxxxoooo
// 辅助任务模型:会话标题生成、提示词优化等「轻量一次性请求」可在设置里单独指定模型,
// 不必占用会话的小模型槽位,也不要求当前会话启用了模型映射。

import Foundation
import OMLog
import ProviderProxyKit

/// 可单独指定模型的辅助任务。
public enum UtilityTask: String, CaseIterable, Sendable {
    /// 会话标题生成
    case title
    /// 提示词优化
    case optimize

    /// 保存选择的偏好键。
    public var preferenceKey: String {
        switch self {
        case .title: ClientPrefs.Key.titleModel
        case .optimize: ClientPrefs.Key.optimizeModel
        }
    }
}

/// 辅助任务的模型选择。
public enum UtilityModelChoice: Equatable, Sendable {
    /// 自动:沿用会话的小模型槽位(无映射时由各任务自行兜底)
    case automatic
    /// 关闭模型调用(仅标题生成使用:只保留首句截取标题)
    case off
    /// 指定提供商的某个模型
    case model(providerId: String, model: String)

    /// 提供商 ID 与模型 ID 的分隔符(避开模型名里常见的字符)。
    static let separator = "\u{1F}"

    /// 由偏好里保存的字符串还原;空串与无法识别的值都按「自动」处理。
    /// - Parameter raw: 偏好原始值
    public init(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .automatic; return }
        if raw == "off" { self = .off; return }
        let parts = raw.components(separatedBy: Self.separator)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            self = .model(providerId: parts[0], model: parts[1])
        } else {
            self = .automatic
        }
    }

    /// 写入偏好的字符串(`automatic` 为空串)。
    public var raw: String {
        switch self {
        case .automatic: ""
        case .off: "off"
        case .model(let providerId, let model): providerId + Self.separator + model
        }
    }
}

/// 辅助任务模型的解析:把「提供商 + 模型」注册成一条本机网关路由。
public enum UtilityModels {
    /// 辅助路由里的模型别名。
    public static let alias = "oma-utility"

    /// 读取某个任务当前的选择。
    /// - Parameters:
    ///   - task: 辅助任务
    ///   - defaults: 偏好存储
    /// - Returns: 模型选择;未设置为 `automatic`
    public static func choice(for task: UtilityTask, defaults: UserDefaults = .standard) -> UtilityModelChoice {
        UtilityModelChoice(raw: defaults.string(forKey: task.preferenceKey))
    }

    /// 解析某个任务应使用的网关入口。
    /// - Parameters:
    ///   - choice: 模型选择
    ///   - fallback: 「自动」或指定模型不可用时使用的入口(通常是会话的小模型槽位)
    ///   - directory: 提供商存储目录(测试可注入)
    ///   - environment: 密钥解析使用的环境(测试可注入)
    ///   - proxy: 代理(测试可注入)
    /// - Returns: 网关地址与模型别名;`off` 或没有任何可用入口时为 nil
    public static func endpoint(for choice: UtilityModelChoice, fallback: (url: URL, alias: String)?,
                                directory: URL = ProviderStorage.defaultDirectory,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                proxy: ProviderProxy = .shared) async -> (url: URL, alias: String)? {
        switch choice {
        case .off:
            return nil
        case .automatic:
            return fallback
        case .model(let providerId, let model):
            if let resolved = await register(providerId: providerId, model: model, directory: directory, environment: environment, proxy: proxy) {
                return resolved
            }
            Log.session.warning("辅助任务指定的模型不可用,回退自动", ["provider": providerId, "model": model])
            return fallback
        }
    }

    /// 校验提供商并把它注册为网关路由(同一「提供商 + 模型」复用同一路由)。
    private static func register(providerId: String, model: String, directory: URL, environment: [String: String], proxy: ProviderProxy) async -> (url: URL, alias: String)? {
        let snapshot = ProviderStorage.load(directory: directory)
        guard let provider = snapshot.providers.first(where: { $0.id == providerId }), provider.isEnabled,
              !model.trimmingCharacters(in: .whitespaces).isEmpty, (try? provider.validate()) != nil else { return nil }
        let secret = ProviderStorage.key(for: providerId, directory: directory, environment: environment)
        if secret == nil, provider.requiresKey { return nil }
        let resolved = ResolvedTarget(slot: .haiku, provider: provider, model: model, key: secret ?? "")
        guard let target = ProviderBridge.target(for: resolved, sessionKey: "utility") else { return nil }
        do {
            let url = try await proxy.register(key: "utility:\(providerId)\(UtilityModelChoice.separator)\(model)", targets: [alias: target], fallback: target)
            return (url, alias)
        } catch {
            Log.session.warning("辅助任务网关注册失败", ["reason": error.localizedDescription])
            return nil
        }
    }
}
