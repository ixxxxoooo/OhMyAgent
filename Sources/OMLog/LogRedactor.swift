// @author ygw
// 日志脱敏:令牌、密钥、授权头、环境变量赋值与可选的家目录路径。

import Foundation

/// 脱敏器(无状态,线程安全)。
public enum LogRedactor {
    /// 需要整体替换的密钥形态与键值赋值形态。
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // Anthropic / OpenAI / GitHub / AWS 等常见令牌前缀
            #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
            #"sk-[A-Za-z0-9]{20,}"#,
            #"gh[pousr]_[A-Za-z0-9]{20,}"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,
            // Authorization / Bearer
            #"(?i)bearer\s+[A-Za-z0-9._\-~+/=]{8,}"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// KEY=VALUE 形式(环境变量、命令行参数)。
    private static let assignment = try? NSRegularExpression(
        pattern: #"(?i)\b([A-Z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|AUTH(?:ORIZATION)?|CREDENTIAL)[A-Z0-9_]*)\s*=\s*("[^"]*"|'[^']*'|\S+)"#)

    /// JSON 形式 `"apiKey": "…"`。
    private static let jsonField = try? NSRegularExpression(
        pattern: #"(?i)("[A-Za-z0-9_\-]*(?:api[_-]?key|token|secret|password|authorization|credential)[A-Za-z0-9_\-]*"\s*:\s*)"(?:[^"\\]|\\.)*""#)

    /// 脱敏文本。
    /// - Parameters:
    ///   - text: 原文
    ///   - hideHome: 是否把家目录替换为 `~`
    /// - Returns: 脱敏后的文本
    public static func redact(_ text: String, hideHome: Bool = false) -> String {
        var result = text
        for regex in patterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "‹已脱敏›")
        }
        if let assignment {
            result = assignment.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1=‹已脱敏›")
        }
        if let jsonField {
            result = jsonField.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\"‹已脱敏›\"")
        }
        if hideHome {
            result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return result
    }

    /// 截断过长文本(用于协议载荷)。
    /// - Parameters:
    ///   - text: 原文
    ///   - limit: 最大字符数
    /// - Returns: 截断后的文本,附带被省略的字符数
    public static func truncate(_ text: String, limit: Int = 2048) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…(省略 \(text.count - limit) 字符)"
    }
}
