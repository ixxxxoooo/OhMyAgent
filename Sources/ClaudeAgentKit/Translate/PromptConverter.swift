// @author ixxxxoooo
// 提示转换器:ACP `session/prompt` 的内容块 → Anthropic 用户消息内容块;以及通知(notice)辅助函数。

import ACPKit
import Foundation

/// ACP 提示 → Claude 用户消息内容。
enum PromptConverter {
    /// 把 URI 渲染成 `[@名称](uri)` 链接(`file://`、`zed://`),其他原样返回。
    /// - Parameter uri: 资源地址
    static func formatUriAsLink(_ uri: String) -> String {
        if uri.hasPrefix("file://") {
            let path = String(uri.dropFirst(7))
            let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
            return "[@\(name)](\(uri))"
        }
        if uri.hasPrefix("zed://") {
            let name = uri.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? uri
            return "[@\(name)](\(uri))"
        }
        return uri
    }

    /// 改写 `/mcp:服务:命令 参数` 为 CLI 识别的 `/服务:命令 (MCP) 参数`。
    static func rewriteMcpCommand(_ text: String) -> String {
        guard text.hasPrefix("/mcp:") else { return text }
        let body = text.dropFirst(5)
        guard let colon = body.firstIndex(of: ":") else { return text }
        let server = body[body.startIndex..<colon]
        guard !server.isEmpty, !server.contains(where: \.isWhitespace) else { return text }
        let rest = body[body.index(after: colon)...]
        let command = rest.prefix { !$0.isWhitespace }
        guard !command.isEmpty else { return text }
        let afterCommand = rest.dropFirst(command.count)
        var args = ""
        if afterCommand.first == " " { args = String(afterCommand.dropFirst()) }
        else if !afterCommand.isEmpty { return text }
        return "/\(server):\(command) (MCP)" + (args.isEmpty ? "" : " \(args)")
    }

    /// 转换提示内容块。
    /// - Parameter prompt: ACP 内容块数组
    /// - Returns: Anthropic 消息内容块(内嵌资源的上下文追加在末尾)
    static func convert(_ prompt: [JSONValue]) -> [JSONValue] {
        var content: [JSONValue] = []
        var context: [JSONValue] = []
        for chunk in prompt {
            switch chunk["type"]?.stringValue {
            case "text":
                content.append(["type": "text", "text": .string(rewriteMcpCommand(chunk["text"]?.stringValue ?? ""))])
            case "resource_link":
                content.append(["type": "text", "text": .string(formatUriAsLink(chunk["uri"]?.stringValue ?? ""))])
            case "resource":
                guard let resource = chunk["resource"], let text = resource["text"]?.stringValue else { continue }
                let uri = resource["uri"]?.stringValue ?? ""
                content.append(["type": "text", "text": .string(formatUriAsLink(uri))])
                context.append(["type": "text", "text": .string("\n<context ref=\"\(uri)\">\n\(text)\n</context>")])
            case "image":
                if let data = chunk["data"]?.nonEmptyString {
                    content.append(["type": "image", "source": ["type": "base64", "data": .string(data), "media_type": chunk["mimeType"] ?? ""]])
                } else if let uri = chunk["uri"]?.stringValue, uri.hasPrefix("http") {
                    content.append(["type": "image", "source": ["type": "url", "url": .string(uri)]])
                }
            default:
                break
            }
        }
        return content + context
    }
}

/// 会话通知(notice)辅助:客户端声明 `session.notices` 时发 `notice`,否则降级为粗体文本消息。
enum Notices {
    /// 通知标题最长长度,超过则正文放进 description。
    static let maxTitleLength = 256

    /// 客户端是否声明了 `session.notices` 能力。
    static func clientSupports(_ capabilities: JSONValue?) -> Bool {
        capabilities?["session"]?["notices"]?.objectValue != nil
    }

    /// 构造 notice 更新体。
    static func update(severity: String, title: String, description: String?) -> JSONValue {
        JSONValue.make([
            ("sessionUpdate", "notice"), ("severity", .string(severity)), ("title", .string(title)),
            ("description", description?.isEmpty == false ? description.map(JSONValue.string) : nil),
        ])
    }

    /// 无通知能力时的文本渲染。
    static func transcriptText(title: String, description: String?) -> String {
        if let description, !description.isEmpty { return "**\(title):** \(description)" }
        return "**\(title)**"
    }

    /// 选择 notice 或降级的 agent 消息。
    static func updateOrTranscript(severity: String, title: String, description: String?, supports: Bool, transcript: String? = nil) -> JSONValue {
        if supports { return update(severity: severity, title: title, description: description) }
        return ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(transcript ?? transcriptText(title: title, description: description))]]
    }

    /// 去掉轻量 Markdown 记号(标题 `#`、粗体、行内代码)。
    static func plainText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "(?m)^[ \\t]*#{1,6}[ \\t]+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(\\*\\*|__)(?=\\S)([\\s\\S]*?\\S)\\1", with: "$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![\\w`])`([^`\\n]+)`(?![\\w`])", with: "$1", options: .regularExpression)
        return result
    }

    /// 把自由文本拆成「标题 + 可选描述」。
    static func split(_ text: String, fallbackTitle: String) -> (title: String, description: String?) {
        let trimmed = plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (fallbackTitle, nil) }
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = String(lines[0]).trimmingCharacters(in: .whitespaces)
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if first.count > maxTitleLength { return (fallbackTitle, trimmed) }
        return rest.isEmpty ? (first, nil) : (first, rest)
    }

    /// 首字母大写。
    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// 折叠空白,用于识别重复文本。
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
