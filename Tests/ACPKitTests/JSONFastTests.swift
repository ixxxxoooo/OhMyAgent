// @author ixxxxoooo
// 手写 JSON 解析与进程内直连传输:与 JSONDecoder 做差分,确保语义一致。

import Foundation
import Testing
@testable import ACPKit

/// 可复现的伪随机数生成器(xorshift)。
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

/// 随机生成 JSON 值(含转义字符、非 ASCII、嵌套)。
private func randomValue(_ rng: inout SeededRNG, depth: Int = 0) -> JSONValue {
    let pool = ["", "a", "hello world", "引号\"与\\反斜杠", "换行\n制表\t回车\r", "控制\u{01}字符\u{1F}", "emoji 😀🎉", "路径/with/slash", "\u{2028}\u{2029}", "é ü 日本語"]
    let kind = Int.random(in: 0..<(depth >= 4 ? 5 : 7), using: &rng)
    switch kind {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &rng))
    case 2: return .int(Int.random(in: -1_000_000...1_000_000, using: &rng))
    case 3:
        let choices: [Double] = [0.5, -2.25, 1e-7, 123456.789, 1e21, 3.14159, -0.001]
        return .double(choices.randomElement(using: &rng) ?? 1.5)
    case 4: return .string(pool.randomElement(using: &rng) ?? "")
    case 5: return .array((0..<Int.random(in: 0...4, using: &rng)).map { _ in randomValue(&rng, depth: depth + 1) })
    default:
        var object: [String: JSONValue] = [:]
        for index in 0..<Int.random(in: 0...4, using: &rng) {
            object["k\(index)" + (pool.randomElement(using: &rng) ?? "")] = randomValue(&rng, depth: depth + 1)
        }
        return .object(object)
    }
}

@Suite("JSON 手写解析")
struct JSONFastTests {
    @Test("随机文档:手写解析与 JSONDecoder 结果一致")
    func parserMatchesDecoder() throws {
        var rng = SeededRNG(state: 0x9E3779B97F4A7C15)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for _ in 0..<400 {
            let value = randomValue(&rng)
            let data = try encoder.encode(value)
            let fast = try JSONValue.parsing(data)
            let reference = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(fast == reference, "文档:\(String(decoding: data, as: UTF8.self))")
        }
    }

    @Test("字面量、转义与代理对")
    func escapesAndLiterals() throws {
        #expect(try JSONValue.parsing(Data(#" {"a":[1,-2,3.5,1e3,true,false,null],"b":"x\u0041\n\ud83d\ude00\/"} "#.utf8))
            == .object(["a": [1, -2, 3.5, 1000.0, true, false, nil], "b": "xA\n😀/"]))
        #expect(try JSONValue.parsing(Data("7".utf8)) == .int(7))
        #expect(try JSONValue.parsing(Data("12345678901234567890".utf8)) == .double(12345678901234567890))
        #expect(try JSONValue.parsing(Data(#""\ud800""#.utf8)) == .string("\u{FFFD}"))
        #expect(try JSONValue.parsing(Data(#"{"a":1,"a":2}"#.utf8)) == .object(["a": 2]))
    }

    @Test("非法输入抛错")
    func invalidInputs() {
        for text in ["", "{", "[1,]", "{\"a\":}", "tru", "01", "1.", "-", "\"abc", "{\"a\" 1}", "[1 2]", "1 2", "\"\\x\"", "\"\u{01}\"", "nul", "{'a':1}"] {
            #expect(throws: JSONParseError.self, "应拒绝:\(text)") { try JSONValue.parsing(Data(text.utf8)) }
        }
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: JSONParseError.self) { try JSONValue.parsing(Data(deep.utf8)) }
    }

    @Test("JSON-RPC 消息往返:请求/通知/响应/错误")
    func rpcRoundTrip() throws {
        let messages: [JSONRPCMessage] = [
            .request(id: .int(7), method: "session/prompt", params: ["text": "你好\n\"x\""]),
            .request(id: .string("abc"), method: "m", params: nil),
            .notification(method: "session/update", params: ["sessionId": "s", "update": ["kind": "x"]]),
            .response(id: .int(1), result: ["ok": true]),
            .errorResponse(id: .int(2), error: JSONRPCError(code: -32601, message: "没有", data: ["details": "d"])),
            .errorResponse(id: nil, error: JSONRPCError(code: -1, message: "无 id")),
        ]
        for message in messages {
            let parsed = try JSONRPCMessage.parse(try message.serialized())
            #expect(parsed == message)
        }
    }

    @Test("回环传输:对端启用直连后消息不经序列化直接投递;未启用时退回行协议")
    func loopbackDirectDelivery() async throws {
        let (a, b) = LoopbackTransport.makePair()
        _ = try a.start()
        let streamB = try b.start()
        let message = JSONRPCMessage.notification(method: "n", params: ["v": 1.0])
        // 未启用:退回行协议
        try a.send(message: message)
        // 启用后:直连
        b.enableDirectMessages()
        try a.send(message: message)
        var received: [TransportEvent] = []
        for await event in streamB {
            received.append(event)
            if received.count == 2 { break }
        }
        guard case .line = received[0], case .message(let direct) = received[1] else {
            Issue.record("事件类型不符:\(received)")
            return
        }
        #expect(direct == message)
    }
}
