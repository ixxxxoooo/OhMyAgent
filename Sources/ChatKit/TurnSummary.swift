// @author ixxxxoooo
// 回合结束语:一轮对话结束后展示的模型名、耗时、token 与生成速度(tps)。

import ACPKit
import Foundation

/// 模型厂商图标的匹配线索(纯数据,由界面层交给 `BrandIcon.resolve`)。
public struct ModelBrandHint: Sendable, Equatable {
    /// 真实模型 ID 或展示名
    public var modelId: String
    /// 提供商预设 ID(可选)
    public var providerPreset: String?
    /// 提供商展示名(兜底与首字母)
    public var providerName: String

    public init(modelId: String, providerPreset: String? = nil, providerName: String? = nil) {
        self.modelId = modelId
        self.providerPreset = providerPreset
        self.providerName = providerName ?? modelId
    }
}

/// 一轮对话的摘要。
public struct TurnSummary: Sendable, Equatable {
    /// 模型显示名(可能为空)
    public var model: String
    /// 整轮耗时(秒,含工具执行)
    public var durationSeconds: Double
    /// 适配器上报的 token 用量(没有时只显示模型与耗时)
    public var usage: TurnUsage?

    /// 厂商图标匹配线索(界面据此解析厂商 logo;为空则按模型名匹配)
    public var brand: ModelBrandHint?

    /// 本轮助手输出的正文(Markdown 原文,多条消息以空行连接);结束行的复制按钮复制它,而不是这一行元数据。
    public var outputText: String

    /// 回合结束的时间(没有时不显示);对齐 Claude Code 的「Cooked for 22s · done 10:20 am」。
    public var finishedAt: Date?

    public init(model: String, durationSeconds: Double, usage: TurnUsage? = nil, brand: ModelBrandHint? = nil, outputText: String = "", finishedAt: Date? = nil) {
        self.finishedAt = finishedAt
        self.outputText = outputText
        self.brand = brand
        self.model = model
        self.durationSeconds = max(durationSeconds, 0)
        self.usage = usage
    }

    /// 输出 token 速度:`输出 token ÷ 耗时`;耗时过短(<0.2 秒)或无输出时为 nil。
    public var tokensPerSecond: Double? {
        guard let usage, usage.outputTokens > 0, durationSeconds >= 0.2 else { return nil }
        return Double(usage.outputTokens) / durationSeconds
    }

    /// 耗时文本:<10 秒保留一位小数,<60 秒取整,否则「分 秒」。
    public var durationText: String {
        let seconds = durationSeconds
        if seconds < 10 { return String(format: String(localized: "%.1f 秒"), seconds) }
        if seconds < 60 { return String(localized: "\(Int(seconds)) 秒") }
        return String(localized: "\(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒")
    }

    /// 展示用的各个片段(模型、耗时、token、tps),已本地化。
    public var parts: [String] {
        var result: [String] = []
        if !model.isEmpty { result.append(model) }
        result.append(durationText)
        if let usage, usage.totalTokens > 0 {
            let input = usage.inputTokens + usage.cachedReadTokens + usage.cachedWriteTokens
            result.append(String(localized: "输入 \(input.formatted()) · 输出 \(usage.outputTokens.formatted()) token"))
        }
        if let tps = tokensPerSecond { result.append(String(format: String(localized: "%.1f tps"), tps)) }
        if let finishedAt { result.append(String(localized: "完成于 \(finishedAt.formatted(date: .omitted, time: .shortened))")) }
        return result
    }

    /// 复制到剪贴板的完整文本。
    public var copyText: String { parts.joined(separator: " · ") }
}
