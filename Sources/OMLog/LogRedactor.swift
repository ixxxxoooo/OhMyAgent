// @author ixxxxoooo
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

    /// HTTP 头形式 `x-api-key: …`、`Authorization: Basic …`(如命令行里的 `curl -H`);值可带一个方案前缀。
    private static let header = try? NSRegularExpression(
        pattern: #"(?i)\b((?:x-)?api-key|x-auth-token|(?:proxy-)?authorization)\s*:\s*(?:[A-Za-z]+\s+)?[^\s"',;]+"#)

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
        if mayContainSecret(text) { result = redactSecrets(result) }
        if hideHome {
            result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return result
    }

    /// 触发词(小写,ASCII):正则命中必然包含其中之一,不含任何触发词的文本可跳过全部正则。
    private static let triggers: [[UInt8]] = [
        "sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "akia", "xox", "bearer",
        "api-key", "api_key", "apikey", "token", "secret", "password", "passwd", "auth", "credential",
    ].map { Array($0.utf8) }

    /// 触发词首字节表(避免逐位置逐词比较)。
    private static let triggerStarts: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for word in triggers { if let first = word.first { table[Int(first)] = true } }
        return table
    }()

    /// 快速判断文本是否可能含需要脱敏的内容(仅可能多报,不会漏报)。
    /// - Parameter text: 原文
    static func mayContainSecret(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { buffer in
            let count = buffer.count
            var index = 0
            while index < count {
                var byte = buffer[index]
                if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                if triggerStarts[Int(byte)] {
                    for word in triggers where word[0] == byte && index + word.count <= count {
                        var matched = true
                        var offset = 1
                        while offset < word.count {
                            var other = buffer[index + offset]
                            if other >= 0x41, other <= 0x5A { other += 0x20 }
                            if other != word[offset] { matched = false; break }
                            offset += 1
                        }
                        if matched { return true }
                    }
                }
                index += 1
            }
            return false
        }
    }

    /// 执行全部脱敏正则(调用前应已用 `mayContainSecret` 过滤)。
    private static func redactSecrets(_ text: String) -> String {
        var result = text
        for regex in patterns {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "‹已脱敏›")
        }
        if let header {
            result = header.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1: ‹已脱敏›")
        }
        if let assignment {
            result = assignment.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1=‹已脱敏›")
        }
        if let jsonField {
            result = jsonField.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\"‹已脱敏›\"")
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
