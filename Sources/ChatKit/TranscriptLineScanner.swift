// @author ixxxxoooo
// 会话记录单行的顶层字段扫描:不构建 JSON 对象树,只用一遍字节扫描取出回合统计需要的几个顶层字段,
// 嵌套对象/数组(如体积巨大的 tool_result、toolUseResult)按括号与字符串规则整体跳过。
// 用于 `TranscriptTurns`:工具结果行占记录体积的大头,且只需要时间戳,没必要整行 `JSONSerialization`。纯函数,便于测试。

import Foundation

/// 一行记录的顶层字段摘要。
struct TranscriptLineFields: Equatable {
    /// `type`(user / assistant / ...)
    var type: String?
    /// `timestamp`(ISO8601 文本)
    var timestamp: String?
    /// `isSidechain` 为 true
    var isSidechain = false
    /// `isMeta` 为 true
    var isMeta = false
    /// 含 `toolUseResult` 或 `sourceToolAssistantUUID` 顶层键(工具结果回灌行,不是用户提问)
    var hasToolMarker = false
}

/// 记录行顶层字段扫描器。
enum TranscriptLineScanner {
    /// 扫描一行 JSON 对象的顶层字段。
    /// - Parameter bytes: 一行的 UTF-8 字节
    /// - Returns: 字段摘要;不是合法的对象行(括号不闭合等)返回 nil,调用方应退回完整解析
    static func scan(_ bytes: UnsafeRawBufferPointer) -> TranscriptLineFields? {
        let count = bytes.count
        var index = 0
        func skipSpace() { while index < count, isSpace(bytes[index]) { index += 1 } }
        /// 从开引号后读到闭引号,返回内容范围(处理反斜杠转义);失败 nil。
        func readString() -> Range<Int>? {
            guard index < count, bytes[index] == quote else { return nil }
            index += 1
            let start = index
            while index < count {
                let byte = bytes[index]
                if byte == backslash { index += 2; continue }
                if byte == quote {
                    defer { index += 1 }
                    return start..<index
                }
                index += 1
            }
            return nil
        }
        /// 跳过一个对象或数组(含其中的字符串)。
        func skipContainer() -> Bool {
            var depth = 0
            while index < count {
                let byte = bytes[index]
                if byte == quote {
                    guard readString() != nil else { return false }
                    continue
                }
                if byte == openBrace || byte == openBracket { depth += 1 }
                if byte == closeBrace || byte == closeBracket {
                    depth -= 1
                    if depth == 0 { index += 1; return true }
                }
                index += 1
            }
            return false
        }
        func text(_ range: Range<Int>) -> String { String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self) }

        skipSpace()
        guard index < count, bytes[index] == openBrace else { return nil }
        index += 1
        var fields = TranscriptLineFields()
        while true {
            skipSpace()
            if index < count, bytes[index] == comma { index += 1; skipSpace() }
            guard index < count else { return nil }
            if bytes[index] == closeBrace { return fields }
            guard let keyRange = readString() else { return nil }
            skipSpace()
            guard index < count, bytes[index] == colon else { return nil }
            index += 1
            skipSpace()
            guard index < count else { return nil }
            let key = text(keyRange)
            switch bytes[index] {
            case quote:
                guard let valueRange = readString() else { return nil }
                switch key {
                case "type": fields.type = text(valueRange)
                case "timestamp": fields.timestamp = text(valueRange)
                case "sourceToolAssistantUUID": fields.hasToolMarker = true
                default: break
                }
            case openBrace, openBracket:
                guard skipContainer() else { return nil }
                if key == "toolUseResult" { fields.hasToolMarker = true }
            default:
                // 数字 / true / false / null:读到分隔符为止
                let start = index
                while index < count, bytes[index] != comma, bytes[index] != closeBrace, !isSpace(bytes[index]) { index += 1 }
                let literal = text(start..<index)
                switch key {
                case "isSidechain": fields.isSidechain = literal == "true"
                case "isMeta": fields.isMeta = literal == "true"
                case "toolUseResult", "sourceToolAssistantUUID": fields.hasToolMarker = true   // 含 null:与完整解析的「键存在」判定一致
                default: break
                }
            }
        }
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
}
