// @author ixxxxoooo
// 模型厂商图标:按模型/提供商匹配、数据可解析渲染、回退首字母。

import Foundation
import Testing

@testable import IconKit

@Suite("模型厂商图标")
struct BrandIconTests {
    @Test("按模型 ID 推断厂商(优先于提供商,聚合平台里的模型也能识别)")
    func matchByModel() {
        #expect(BrandIcon.resolve(modelId: "deepseek-chat", providerPreset: "opencode", providerName: "OpenCode Zen") == .vector("deepseek"))
        #expect(BrandIcon.resolve(modelId: "claude-sonnet-4-5", providerPreset: "opencode", providerName: "x") == .vector("claude"))
        #expect(BrandIcon.resolve(modelId: "gpt-5-codex", providerPreset: nil, providerName: "x") == .vector("openai"))
        #expect(BrandIcon.resolve(modelId: "glm-4.6", providerPreset: nil, providerName: "x") == .vector("zhipu"))
        #expect(BrandIcon.resolve(modelId: "kimi-k2", providerPreset: nil, providerName: "x") == .vector("kimi"))
        #expect(BrandIcon.resolve(modelId: "Qwen3-Coder", providerPreset: nil, providerName: "x") == .vector("qwen"))
        #expect(BrandIcon.resolve(modelId: "anthropic/claude-3.5", providerPreset: "openrouter", providerName: "OpenRouter") == .vector("anthropic"))
        #expect(BrandIcon.resolve(modelId: "meta-llama/llama-3", providerPreset: "openrouter", providerName: "OpenRouter") == .vector("meta"))
    }

    @Test("模型无法识别时回退到提供商;都不认识时用首字母")
    func fallback() {
        #expect(BrandIcon.resolve(modelId: "big-pickle", providerPreset: "opencode", providerName: "OpenCode Zen") == .vector("opencode"))
        #expect(BrandIcon.resolve(providerPreset: nil, providerName: "智谱 GLM") == .vector("zhipu"))
        #expect(BrandIcon.resolve(modelId: "foo", providerPreset: nil, providerName: "我的网关") == .initial("我"))
        #expect(BrandIcon.resolve(modelId: "foo", providerPreset: nil, providerName: "acme") == .initial("A"))
        #expect(BrandIcon.resolve(providerPreset: nil, providerName: "  ") == .initial("?"))
    }

    @Test("内置预设对应的厂商图标数据齐全且可解析、可渲染")
    func dataRenders() {
        for name in ["anthropic", "claude", "openai", "gemini", "deepseek", "qwen", "kimi", "zhipu", "minimax", "openrouter", "ollama", "lmstudio", "opencode", "grok", "mistral", "meta"] {
            #expect(BrandIconData.icons[name] != nil, "缺少 \(name)")
            #expect(BrandIconRenderer.nsImage(name, size: 14) != nil, "\(name) 渲染失败")
        }
        #expect(BrandIconRenderer.nsImage("不存在", size: 14) == nil)
    }

    @Test("规则里引用的图标键都在数据里(防止拼写错误)")
    func rulesReferenceExistingData() {
        let probes = ["claude", "gpt", "gemma", "gemini", "deepseek", "qwen", "kimi", "glm", "minimax", "grok", "mistral", "llama", "doubao", "step-", "ernie", "hunyuan", "mimo", "longcat", "command-r", "nemotron", "sonar", "internlm", "jamba"]
        for probe in probes {
            if case .initial = BrandIcon.resolve(modelId: probe, providerPreset: nil, providerName: "x") { Issue.record("规则 \(probe) 没有可用图标") }
        }
    }
}
