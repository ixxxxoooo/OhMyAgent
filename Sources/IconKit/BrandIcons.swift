// @author ixxxxoooo
// 模型厂商图标:按「模型 ID → 提供商预设/名称」推断厂商,渲染 lobe-icons 单色图标(模板着色);
// 找不到厂商时回退为首字母徽标。纯逻辑部分(匹配)与视图分离,便于测试。

import AppKit
import Foundation
import OMLog
import SwiftUI

/// 厂商图标的匹配结果。
public enum BrandIcon: Equatable, Sendable {
    /// 矢量厂商图标(`BrandIconData` 中的键)
    case vector(String)
    /// 回退:首字母徽标
    case initial(Character)

    /// 模型 ID 子串 → 厂商图标键(顺序即优先级;更具体的写在前面)。
    private static let modelRules: [(needle: String, icon: String)] = [
        ("claude", "claude"), ("sonnet", "claude"), ("opus", "claude"), ("haiku", "claude"), ("fable", "claude"), ("anthropic", "anthropic"),
        ("gpt", "openai"), ("chatgpt", "openai"), ("codex", "codex"), ("davinci", "openai"),
        ("gemma", "gemma"), ("gemini", "gemini"),
        ("deepseek", "deepseek"),
        ("qwen", "qwen"), ("qwq", "qwen"),
        ("kimi", "kimi"), ("moonshot", "moonshot"),
        ("glm", "zhipu"), ("zhipu", "zhipu"),
        ("minimax", "minimax"),
        ("grok", "grok"),
        ("mistral", "mistral"), ("mixtral", "mistral"), ("codestral", "mistral"), ("devstral", "mistral"), ("magistral", "mistral"),
        ("llama", "meta"),
        ("doubao", "doubao"), ("seed-", "doubao"),
        ("step-", "stepfun"),
        ("baichuan", "baichuan"),
        ("ernie", "wenxin"),
        ("hunyuan", "hunyuan"),
        ("mimo", "xiaomimimo"),
        ("longcat", "longcat"),
        ("command-r", "cohere"),
        ("nemotron", "nvidia"),
        ("sonar", "perplexity"),
        ("internlm", "internlm"),
        ("jamba", "ai21"),
    ]

    /// 提供商预设 ID / 名称关键字 → 厂商图标键(模型无法识别时使用)。
    private static let providerRules: [(needle: String, icon: String)] = [
        ("antigravity", "gemini"), ("anthropic", "anthropic"), ("openrouter", "openrouter"), ("opencode", "opencode"),
        ("openai", "openai"), ("gemini", "gemini"), ("google", "google"),
        ("deepseek", "deepseek"), ("glm", "zhipu"), ("zhipu", "zhipu"), ("智谱", "zhipu"),
        ("kimi", "kimi"), ("moonshot", "moonshot"), ("minimax", "minimax"),
        ("qwen", "qwen"), ("百炼", "bailian"), ("dashscope", "bailian"), ("alibaba", "alibaba"),
        ("ollama", "ollama"), ("lmstudio", "lmstudio"), ("lm studio", "lmstudio"),
        ("groq", "groq"), ("together", "together"), ("fireworks", "fireworks"), ("siliconflow", "siliconcloud"),
        ("volc", "volcengine"), ("豆包", "doubao"), ("mistral", "mistral"), ("cohere", "cohere"),
        ("nvidia", "nvidia"), ("huggingface", "huggingface"), ("perplexity", "perplexity"),
        ("xai", "xai"), ("grok", "grok"), ("azure", "azure"), ("bedrock", "bedrock"), ("cloudflare", "cloudflare"),
        ("vercel", "vercel"), ("github", "github"), ("cerebras", "cerebras"), ("sambanova", "sambanova"),
        ("novita", "novita"), ("nebius", "nebius"), ("replicate", "replicate"),
    ]

    /// 推断某个模型的厂商图标。
    /// - Parameters:
    ///   - modelId: 发给上游的模型 ID(如 `deepseek-chat`、`anthropic/claude-sonnet-4.5`)
    ///   - providerPreset: 提供商来源预设 ID(可空)
    ///   - providerName: 提供商展示名(用于自定义提供商的兜底匹配和首字母)
    /// - Returns: 厂商矢量图标;都不命中时返回首字母徽标
    public static func resolve(modelId: String, providerPreset: String?, providerName: String) -> BrandIcon {
        let model = modelId.lowercased()
        // `厂商/模型` 形式(OpenRouter 等聚合平台)优先看斜杠前的厂商
        if let slash = model.firstIndex(of: "/") {
            let vendor = String(model[model.startIndex..<slash])
            if let hit = providerRules.first(where: { vendor.contains($0.needle) }), BrandIconData.icons[hit.icon] != nil { return .vector(hit.icon) }
        }
        if let hit = modelRules.first(where: { model.contains($0.needle) }), BrandIconData.icons[hit.icon] != nil { return .vector(hit.icon) }
        return resolve(providerPreset: providerPreset, providerName: providerName)
    }

    /// 只按提供商推断(设置页提供商列表、分组标题用)。
    /// - Parameters:
    ///   - providerPreset: 来源预设 ID(可空)
    ///   - providerName: 提供商展示名
    /// - Returns: 厂商矢量图标或首字母徽标
    public static func resolve(providerPreset: String?, providerName: String) -> BrandIcon {
        let haystacks = [providerPreset?.lowercased() ?? "", providerName.lowercased()]
        for text in haystacks where !text.isEmpty {
            if let hit = providerRules.first(where: { text.contains($0.needle) }), BrandIconData.icons[hit.icon] != nil { return .vector(hit.icon) }
        }
        let letter = providerName.trimmingCharacters(in: .whitespaces).first.map { Character(String($0).uppercased()) } ?? "?"
        return .initial(letter)
    }
}

/// 厂商图标渲染器(SVG path → 模板 NSImage,带缓存)。
public enum BrandIconRenderer {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: (path: Path, evenOdd: Bool)] = [:]
        private let images = NSCache<NSString, NSImage>()

        func path(_ name: String) -> (path: Path, evenOdd: Bool)? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = paths[name] { return cached }
            guard let data = BrandIconData.icons[name] else { return nil }
            do {
                let entry = (path: try SVGPathParser.parse(all: data.paths), evenOdd: data.evenOdd)
                paths[name] = entry
                return entry
            } catch {
                Log.ui.error("厂商图标路径解析失败", error: error, ["icon": name])
                return nil
            }
        }

        func image(_ key: String) -> NSImage? { images.object(forKey: key as NSString) }
        func store(_ image: NSImage, _ key: String) { images.setObject(image, forKey: key as NSString) }
    }

    private static let cache = Cache()

    /// 生成厂商图标的模板 NSImage。
    /// - Parameters:
    ///   - name: `BrandIconData` 的键
    ///   - size: 边长(点)
    /// - Returns: 模板图像;未知名称返回 nil
    public static func nsImage(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(size)"
        if let cached = cache.image(key) { return cached }
        guard let entry = cache.path(name) else { return nil }
        let cgPath = entry.path.cgPath
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(cgPath)
            context.drawPath(using: entry.evenOdd ? .eoFill : .fill)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        cache.store(image, key)
        return image
    }
}

/// 厂商图标视图:矢量图标随前景色着色;回退为圆角首字母徽标。
public struct BrandIconView: View {
    private let icon: BrandIcon
    private let size: CGFloat

    /// - Parameters:
    ///   - icon: 匹配结果
    ///   - size: 边长(点),默认 14
    public init(_ icon: BrandIcon, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        switch icon {
        case .vector(let name):
            if let image = BrandIconRenderer.nsImage(name, size: size) {
                Image(nsImage: image).renderingMode(.template).frame(width: size, height: size)
            } else {
                badge("?")
            }
        case .initial(let letter):
            badge(String(letter))
        }
    }

    private func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.quaternary))
    }
}
