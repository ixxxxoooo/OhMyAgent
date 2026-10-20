// @author ixxxxoooo
// ClaudeAgentKit 内部使用的 JSON 小工具:路径取值、对象构造、序列化。

import ACPKit
import Foundation

extension JSONValue {
    /// 按键路径逐层取值,任一层缺失返回 nil。
    /// - Parameter keys: 键路径
    func at(_ keys: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in keys {
            guard let next = current?[key] else { return nil }
            current = next
        }
        return current
    }

    /// 非 null 且非空串的字符串。
    var nonEmptyString: String? {
        guard let text = stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// 构造对象,自动丢弃值为 nil 的键。
    /// - Parameter pairs: 键值对
    static func make(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (key, value) in pairs {
            if let value { object[key] = value }
        }
        return .object(object)
    }

    /// 序列化为一行 UTF-8 JSON(键有序,斜杠不转义)。
    /// - Returns: 序列化数据;失败返回 nil
    func serialized() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    /// 解析一段 JSON 数据。
    /// - Parameter data: UTF-8 数据
    /// - Returns: 解析结果;失败返回 nil
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 解析一段 JSON 文本。
    /// - Parameter text: JSON 文本
    /// - Returns: 解析结果;失败返回 nil
    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// 紧凑 JSON 文本(键有序),用于传给 `claude` 的命令行参数。
    var jsonText: String {
        String(decoding: serialized() ?? Data("null".utf8), as: UTF8.self)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// 转为 `JSONValue.object`。
    var json: JSONValue { .object(self) }
}
