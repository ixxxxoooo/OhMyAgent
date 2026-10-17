// @author ixxxxoooo
// 会话标题自动生成(Cursor 风格):首条用户消息后,先用首句截取作为临时标题,
// 再经本机模型网关用小模型槽位异步生成 3~8 字的短标题覆盖。

import Foundation
import OMLog

/// 标题来源,数值越大优先级越高:手动重命名 > 适配器推送 > 模型生成 > 截取。
public enum TitleSource: Int, Comparable, Sendable {
    case none = 0
    case truncated
    case generated
    case adapter
    case manual

    public static func < (lhs: TitleSource, rhs: TitleSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 会话标题生成器(纯逻辑 + 一次轻量网关请求)。
public enum TitleGenerator {
    /// 截取标题的最大字数
    public static let fallbackLimit = 30
    /// 生成标题的最大字数(超出则截断)
    public static let generatedLimit = 24

    /// 由首条用户消息截取临时标题:取首个非空行、折叠空白、去掉常见前缀,超长加省略号。
    /// - Parameter prompt: 用户消息
    /// - Returns: 临时标题;消息为空时返回 nil
    public static func fallbackTitle(from prompt: String) -> String? {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard var line = firstLine else { return nil }
        // 斜杠命令、@提及不适合作标题开头
        while line.hasPrefix("/") || line.hasPrefix("@") {
            guard let space = line.firstIndex(of: " ") else { return nil }
            line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return truncate(line, limit: fallbackLimit)
    }

    /// 清洗模型返回的标题:去引号、标点、前缀「标题:」、多行只取首行,并限制长度。
    /// - Parameter raw: 模型原始输出
    /// - Returns: 可用标题;无有效内容返回 nil
    public static func cleanGenerated(_ raw: String) -> String? {
        guard var text = raw.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        for prefix in ["标题:", "标题：", "Title:", "title:", "Title：", "会话标题:", "会话标题："] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let trim = CharacterSet(charactersIn: "\"'“”‘’「」『』《》`*#。.,，!！?？;；:：")
        text = text.trimmingCharacters(in: trim.union(.whitespaces))
        guard !text.isEmpty else { return nil }
        return truncate(text, limit: generatedLimit)
    }

    /// 生成标题的提示词。
    /// - Parameter userText: 用户首条消息(会被截断,避免大段内容浪费 token)
    public static func prompt(for userText: String) -> String {
        let snippet = truncate(userText.trimmingCharacters(in: .whitespacesAndNewlines), limit: 600)
        return """
        请为下面这条对话开头起一个简短的会话标题:3 到 8 个字,概括用户想做的事,不要标点、引号和前缀,与用户使用同一种语言。只输出标题本身。

        \(snippet)
        """
    }

    /// 构造 Anthropic Messages 请求体(无工具、极小的 `max_tokens`)。
    /// - Parameters:
    ///   - model: 网关模型别名(如 `oma-small`)
    ///   - userText: 用户首条消息
    /// - Returns: JSON 数据
    public static func requestBody(model: String, userText: String) -> Data? {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 40,
            "stream": false,
            "messages": [["role": "user", "content": prompt(for: userText)]],
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// 从 Anthropic Messages 响应里取出文本。
    /// - Parameter data: 响应体
    /// - Returns: 拼接后的文本;解析失败返回 nil
    public static func responseText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return text.isEmpty ? nil : text
    }

    /// 经本机模型网关生成标题。
    /// - Parameters:
    ///   - gateway: 本机网关地址(路由令牌在路径里,真实密钥只在网关内存)
    ///   - model: 网关模型别名
    ///   - userText: 用户首条消息
    ///   - timeout: 请求超时
    ///   - session: URLSession(测试可注入)
    /// - Returns: 清洗后的标题;失败返回 nil
    public static func generate(gateway: URL, model: String, userText: String, timeout: TimeInterval = 15, session: URLSession = .shared) async -> String? {
        guard let body = requestBody(model: model, userText: userText) else { return nil }
        var request = URLRequest(url: gateway.appendingPathComponent("v1/messages"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(ProviderLaunch.placeholderToken, forHTTPHeaderField: "x-api-key")
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.session.warning("生成标题失败", ["status": "\((response as? HTTPURLResponse)?.statusCode ?? -1)"])
                return nil
            }
            let title = responseText(from: data).flatMap(cleanGenerated)
            Log.session.info("生成标题完成", ["ms": "\(OMLogger.milliseconds(since: started))", "ok": "\(title != nil)"])
            return title
        } catch {
            Log.session.warning("生成标题请求出错", ["reason": error.localizedDescription])
            return nil
        }
    }

    /// 按字符数截断,超长以省略号结尾。
    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
