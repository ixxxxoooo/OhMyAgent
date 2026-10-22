// @author ixxxxoooo
// JSONValue 的手写解析器:绕开 `Codable` 的逐类型试探(`try?` 级联会为每个值构造并丢弃错误对象),
// 用于 ACP 与 `claude` 输出的高频行解析;语义与 `JSONDecoder` 对齐(差分测试守卫)。
// 序列化仍用 `JSONEncoder`:基准显示它比手写写出器更快(出站消息也小得多)。

import Foundation

/// JSON 文本不合法时抛出。
public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    /// 出错的字节偏移
    public let offset: Int
    /// 原因
    public let reason: String

    public var description: String { "JSON 解析失败(偏移 \(offset)):\(reason)" }
}

public extension JSONValue {
    /// 最大嵌套深度。比 `JSONDecoder` 的 512 更保守:递归下降在协作线程池的小栈(512KB)上运行,
    /// 调试构建的栈帧很大,512 层会栈溢出;ACP 与 Claude 输出的真实嵌套远小于此。
    static let maxParseDepth = 128

    /// 手写解析一段 JSON。
    ///
    /// 数字规则:无小数点与指数且能放进 `Int` 的为 `.int`,其余为 `.double`;对象重复键以后者为准;
    /// 顶层允许标量(与 `JSONDecoder` 解码 `JSONValue` 一致)。
    /// - Parameter data: UTF-8 数据
    /// - Returns: 解析结果
    /// - Throws: `JSONParseError`
    static func parsing(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var parser = JSONFastParser(bytes: raw.bindMemory(to: UInt8.self))
            return try parser.parseDocument()
        }
    }
}

// MARK: - 解析

/// 基于字节缓冲的递归下降解析器(只读、无拷贝切片)。
struct JSONFastParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    /// 解析整份文档(含前后空白,不允许多余内容)。
    mutating func parseDocument() throws -> JSONValue {
        // 容忍 UTF-8 BOM
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if index != bytes.count { throw fail("值之后存在多余内容") }
        return value
    }

    private func fail(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 } else { break }
        }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= JSONValue.maxParseDepth else { throw fail("嵌套过深") }
        guard index < bytes.count else { throw fail("意外的结尾") }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6E: try expect("null"); return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: throw fail("无法识别的值")
        }
    }

    private mutating func expect(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw fail("意外的结尾") }
        let matches = literal.withUTF8Buffer { expected in
            for offset in 0..<count where bytes[index + offset] != expected[offset] { return false }
            return true
        }
        guard matches else { throw fail("无法识别的字面量") }
        index += count
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1   // {
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x7D { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw fail("对象键必须是字符串") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { throw fail("缺少冒号") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw fail("意外的结尾") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x7D { index += 1; return .object(object) }
            throw fail("对象中应为逗号或右花括号")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1   // [
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x5D { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw fail("意外的结尾") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x5D { index += 1; return .array(array) }
            throw fail("数组中应为逗号或右方括号")
        }
    }

    /// 数字:严格 JSON 语法;整数放得进 `Int` 则为 `.int`,否则 `.double`。
    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isInteger = true
        if bytes[index] == 0x2D { index += 1 }
        guard index < bytes.count else { throw fail("数字不完整") }
        if bytes[index] == 0x30 {
            index += 1
        } else if bytes[index] >= 0x31, bytes[index] <= 0x39 {
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        } else {
            throw fail("数字格式错误")
        }
        if index < bytes.count, bytes[index] == 0x2E {
            isInteger = false
            index += 1
            let digitsStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            if index == digitsStart { throw fail("小数点后缺少数字") }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            let digitsStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            if index == digitsStart { throw fail("指数缺少数字") }
        }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<index])
        let text = String(decoding: slice, as: UTF8.self)
        if isInteger, let value = Int(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { throw fail("数字超出范围") }
        return .double(value)
    }

    /// 字符串:无转义时整段拷贝(快路径),含转义时逐字节还原(含 `\uXXXX` 与代理对)。
    private mutating func parseString() throws -> String {
        index += 1   // 开头引号
        let start = index
        // 快路径:扫描到结束引号,期间没有转义与控制字符
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return text
            }
            if byte == 0x5C { break }
            if byte < 0x20 { throw fail("字符串含未转义的控制字符") }
            index += 1
        }
        guard index < bytes.count else { throw fail("字符串未结束") }
        // 慢路径:已扫描的前缀 + 逐字节处理转义
        var buffer = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<index]))
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte < 0x20 { throw fail("字符串含未转义的控制字符") }
            if byte != 0x5C { buffer.append(byte); index += 1; continue }
            index += 1
            guard index < bytes.count else { throw fail("转义不完整") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22: buffer.append(0x22)
            case 0x5C: buffer.append(0x5C)
            case 0x2F: buffer.append(0x2F)
            case 0x62: buffer.append(0x08)
            case 0x66: buffer.append(0x0C)
            case 0x6E: buffer.append(0x0A)
            case 0x72: buffer.append(0x0D)
            case 0x74: buffer.append(0x09)
            case 0x75:
                var scalarValue = try parseHex4()
                if (0xD800...0xDBFF).contains(scalarValue) {
                    // 高代理项:必须紧跟 \uXXXX 低代理项
                    if index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else {
                        scalarValue = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(scalarValue) {
                    scalarValue = 0xFFFD
                }
                let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: throw fail("无效的转义序列")
            }
        }
        throw fail("字符串未结束")
    }

    /// 读取 4 位十六进制数。
    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("\\u 转义不完整") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw fail("\\u 转义含非法字符")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }
}
