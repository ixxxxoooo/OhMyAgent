// @author ixxxxoooo
// 提供商的模型清单、协议类型、命名去重与输入框模型菜单的构建逻辑(纯数据,无视图)。

import Foundation

/// 提供商使用的 API 协议。
public enum ProviderProtocol: String, Codable, CaseIterable, Sendable {
    /// Anthropic Messages 协议:Claude Code 直连
    case anthropic
    /// OpenAI Chat Completions 协议:经本地协议代理转换
    case openai

    /// 设置页展示名。
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }
}

/// 提供商下的一个模型条目。
public struct ProviderModel: Codable, Identifiable, Hashable, Sendable {
    /// 模型 ID(发给上游的名字)
    public var id: String
    /// 展示名(可重命名;nil 或空表示使用 ID)
    public var displayName: String?
    /// 是否出现在输入框的模型菜单
    public var enabled: Bool
    /// 该模型的上下文窗口(token);nil 沿用提供商级设置
    public var contextWindow: Int?

    public init(id: String, displayName: String? = nil, enabled: Bool = true, contextWindow: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.contextWindow = contextWindow
    }

    /// 界面展示名(重命名优先)。
    public var name: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }
}

extension ModelProvider {
    /// 是否走 OpenAI 协议(需要本地协议代理)。
    public var isOpenAIProtocol: Bool { protocolKind == .openai }

    /// 是否启用(默认启用)。
    public var isEnabled: Bool { enabled != false }

    /// 是否必须填写密钥(本地模型等可不填)。
    public var requiresKey: Bool { keyOptional != true }

    /// 当前生效的模型清单:已显式维护的 `models`,否则由旧字段(主模型 + availableModels)推导。
    public var modelList: [ProviderModel] {
        if let models { return models }
        var ids = [model]
        for name in availableModels ?? [] where !ids.contains(name) { ids.append(name) }
        return ids.filter { !$0.isEmpty }.map { ProviderModel(id: $0) }
    }

    /// 输入框菜单可选的模型(已启用),主模型始终包含在首位。
    public var menuModels: [ProviderModel] {
        var result = modelList.filter(\.enabled)
        if !model.isEmpty, !result.contains(where: { $0.id == model }) {
            result.insert(modelList.first(where: { $0.id == model }) ?? ProviderModel(id: model), at: 0)
        }
        return result
    }

    /// 模型 ID 对应的展示名(未登记的原样返回)。
    /// - Parameter id: 模型 ID
    public func displayName(forModel id: String) -> String {
        modelList.first(where: { $0.id == id })?.name ?? id
    }

    /// 当前主模型生效的上下文窗口:模型级优先于提供商级。
    public var effectiveContextWindow: Int? {
        modelList.first(where: { $0.id == model })?.contextWindow ?? contextWindow
    }

    /// 旧数据迁移:把 `availableModels` 并入 `models` 并清除旧字段。
    /// - Returns: 迁移后的副本
    public func migrated() -> ModelProvider {
        guard models == nil, availableModels != nil else { return self }
        var copy = self
        copy.models = modelList
        copy.availableModels = nil
        return copy
    }

    /// 合并一批模型 ID:已有的保留(含重命名与启用状态),新的以启用状态追加。
    /// - Parameters:
    ///   - ids: 要加入的模型 ID
    ///   - enabled: 新增项的启用状态
    public mutating func mergeModels(_ ids: [String], enabled: Bool = true) {
        var list = modelList
        for id in ids where !id.isEmpty && !list.contains(where: { $0.id == id }) {
            list.append(ProviderModel(id: id, enabled: enabled))
        }
        models = list
        availableModels = nil
    }
}

/// 提供商命名:同名自动加序号。
public enum ProviderNaming {
    /// 生成不与现有名称冲突的名称(`自定义` → `自定义 2` → `自定义 3`)。
    /// - Parameters:
    ///   - base: 期望的名称
    ///   - existing: 已被占用的名称
    /// - Returns: 唯一名称
    public static func uniqueName(_ base: String, existing: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let root = trimmed.isEmpty ? "Provider" : trimmed
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var counter = 2
        while taken.contains("\(root) \(counter)".lowercased()) { counter += 1 }
        return "\(root) \(counter)"
    }
}

/// 输入框模型菜单的一个分组(一个提供商)。
public struct ProviderMenuSection: Identifiable, Equatable, Sendable {
    public var id: String { providerId }
    public var providerId: String
    public var providerName: String
    public var models: [ProviderModel]
}

/// 输入框模型菜单的构建:跨提供商的扁平列表,按厂商分组,只含已启用且已配置密钥的模型。
public enum ProviderMenuBuilder {
    /// 构建分组。
    /// - Parameters:
    ///   - snapshot: 提供商快照
    ///   - hasKey: 判断某提供商是否已有密钥
    ///   - query: 搜索词(匹配厂商名、模型展示名与 ID;空表示全部)
    /// - Returns: 非空分组(厂商名命中时保留该厂商的全部模型)
    public static func sections(snapshot: ProviderSnapshot, hasKey: (String) -> Bool, query: String = "") -> [ProviderMenuSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [ProviderMenuSection] = []
        for provider in snapshot.providers where provider.isEnabled && (!provider.requiresKey || hasKey(provider.id)) {
            var models = provider.menuModels
            if !needle.isEmpty, !provider.name.lowercased().contains(needle) {
                models = models.filter { $0.name.lowercased().contains(needle) || $0.id.lowercased().contains(needle) }
            }
            if !models.isEmpty { result.append(ProviderMenuSection(providerId: provider.id, providerName: provider.name, models: models)) }
        }
        return result
    }
}
