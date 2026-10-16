// @author ixxxxoooo
// Anthropic 请求体的顶层 `model` 字段读取与改写。
//
// 热路径优化:Claude Code 序列化的请求体里 `model` 是第一个键(`{"model":"…","max_tokens":…`),
// 因此先在开头 512 字节内做字节级定位,只替换这一小段,不必解析/重新序列化可能包含大图的整个请求体;
// 定位失败才回退到完整 JSON 解析。字符串内容里的引号总是被转义,不会与顶层键混淆。

import Foundation

/// 请求体 `model` 字段工具。
enum ModelRewriter {
    /// 定位结果:模型名及其值(不含引号)在 `bytes` 中的范围。
    struct Location {
        var name: String
        var range: Range<Int>
    }

    private static let key = Array("\"model\"".utf8)
    private static let scanWindow = 512

    /// 读取顶层 `model`。
    /// - Parameter body: 请求体
    /// - Returns: 模型名;读不到返回 nil
    static func peekModel(_ body: Data) -> String? {
        if let location = locate(body) { return location.name }
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return root["model"] as? String
    }

    /// 把顶层 `model` 改写为新值。
    /// - Parameters:
    ///   - body: 请求体
    ///   - model: 新模型名
    /// - Returns: 改写后的请求体;无法改写返回原体
    static func rewrite(_ body: Data, to model: String) -> Data {
        if let location = locate(body) {
            var out = Data()
            out.reserveCapacity(body.count + model.utf8.count)
            out.append(body.prefix(location.range.lowerBound))
            out.append(contentsOf: escape(model).utf8)
            out.append(body.suffix(from: body.startIndex + location.range.upperBound))
            return out
        }
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        root["model"] = model
        return (try? JSONSerialization.data(withJSONObject: root)) ?? body
    }

    /// 在开头窗口内字节级定位 `"model":"值"`。
    static func locate(_ body: Data) -> Location? {
        let limit = min(body.count, scanWindow)
        guard limit > key.count else { return nil }
        return body.withUnsafeBytes { raw -> Location? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + key.count <= limit {
                if bytes[index] == key[0], matches(bytes, at: index) {
                    var cursor = index + key.count
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count, bytes[cursor] == 0x3A else { index += 1; continue }
                    cursor += 1
                    while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count, bytes[cursor] == 0x22 else { index += 1; continue }
                    let start = cursor + 1
                    var end = start
                    while end < bytes.count {
                        if bytes[end] == 0x5C { end += 2; continue }
                        if bytes[end] == 0x22 { break }
                        end += 1
                    }
                    guard end < bytes.count else { return nil }
                    let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
                    return Location(name: name, range: start..<end)
                }
                index += 1
            }
            return nil
        }
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        for offset in 0..<key.count where bytes[index + offset] != key[offset] { return false }
        return true
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    /// JSON 字符串转义(只处理引号、反斜杠与控制字符)。
    private static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
