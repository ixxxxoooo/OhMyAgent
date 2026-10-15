// @author ygw
// OMLog 单元测试:脱敏、级别过滤、行格式、轮转、清理、并发写入、订阅。

import Foundation
import Testing
@testable import OMLog

private func tempDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oma-log-\(UUID().uuidString)", isDirectory: true)
}

@Suite("日志脱敏")
struct RedactorTests {
    @Test("常见令牌与授权头被替换")
    func tokens() {
        let text = "key sk-ant-api03-ABCDEFGH12345678 and ghp_abcdefghijklmnopqrstuvwxyz0123 Authorization: Bearer abc.def-123456789"
        let result = LogRedactor.redact(text)
        #expect(!result.contains("ABCDEFGH12345678"))
        #expect(!result.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!result.contains("abc.def-123456789"))
        #expect(result.contains("‹已脱敏›"))
    }

    @Test("环境变量赋值与 JSON 字段被替换,普通文本保留")
    func assignments() {
        let result = LogRedactor.redact(#"ANTHROPIC_API_KEY=secret123 PATH=/usr/bin {"apiKey": "abc", "name": "x"} MY_TOKEN="a b""#)
        #expect(!result.contains("secret123"))
        #expect(result.contains("PATH=/usr/bin"))
        #expect(result.contains(#""name": "x""#))
        #expect(!result.contains(#""abc""#))
        #expect(!result.contains("a b"))
    }

    @Test("家目录可选替换为 ~,长文本截断")
    func homeAndTruncate() {
        let text = "\(NSHomeDirectory())/proj"
        #expect(LogRedactor.redact(text, hideHome: true) == "~/proj")
        #expect(LogRedactor.redact(text) == text)
        #expect(LogRedactor.truncate(String(repeating: "a", count: 100), limit: 10).hasPrefix("aaaaaaaaaa…(省略 90"))
    }
}

@Suite("日志系统")
struct LogSystemTests {
    @Test("级别过滤与行格式")
    func levelAndFormat() {
        let system = LogSystem(level: .warning, osLog: false)
        let logger = OMLogger(.acp, system: system, context: ["session": "s1"])
        logger.info("不应出现")
        logger.warning("慢请求", ["ms": "2500", "method": "session/prompt x"])
        let recent = system.recent()
        #expect(recent.count == 1)
        let line = recent[0].line
        #expect(line.contains("WARN  [acp] 慢请求"))
        #expect(line.contains("method=\"session/prompt x\""))
        #expect(line.contains("ms=2500"))
        #expect(line.contains("session=s1"))
        #expect(!line.contains("\n"))
    }

    @Test("消息中的密钥在写入前脱敏,多行值不换行")
    func redactsOnLog() {
        let system = LogSystem(level: .debug, osLog: false)
        OMLogger(.agent, system: system).info("启动 ANTHROPIC_API_KEY=abc123", ["note": "a\nb"])
        let line = system.recent()[0].line
        #expect(!line.contains("abc123"))
        #expect(!line.contains("\n"))
        #expect(line.contains("a\\nb"))
    }

    @Test("文件落盘包含完整行,且并发写入不丢失")
    func concurrentWrites() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = LogSystem(directory: dir, level: .debug, osLog: false)
        let logger = OMLogger(.session, system: system)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask { for index in 0..<125 { logger.info("消息", ["w": "\(worker)", "i": "\(index)"]) } }
            }
        }
        system.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("oma-") }
        let lines = try files.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        #expect(lines.count == 1000)
        #expect(lines.allSatisfy { $0.contains("[session] 消息") })
    }

    @Test("订阅能收到新日志")
    func streaming() async {
        let system = LogSystem(level: .debug, osLog: false)
        let stream = system.stream()
        OMLogger(.ui, system: system).info("你好")
        var iterator = stream.makeAsyncIterator()
        let entry = await iterator.next()
        #expect(entry?.message == "你好")
    }

    @Test("协议流量只在开启时落盘,载荷脱敏并截断")
    func traffic() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = LogSystem(directory: dir, osLog: false)
        system.traffic("→", "initialize #1", payload: "x")
        system.flush()
        let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("acp-traffic") }) ?? []
        #expect(before.isEmpty)
        system.trafficEnabled = true
        system.traffic("←", "session/update", payload: #"{"token":"abc","text":"\#(String(repeating: "z", count: 5000))"}"#)
        system.flush()
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("acp-traffic") })
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("← session/update"))
        #expect(!content.contains("\"abc\""))
        #expect(content.contains("省略"))
        #expect(!content.contains("initialize #1"))
    }
}

@Suite("日志文件写入器")
struct WriterTests {
    @Test("超过上限后轮转并限制文件个数")
    func rotation() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = LogFileWriter(directory: dir, prefix: "t", maxBytes: 1024, maxFiles: 3)
        for index in 0..<200 { writer.append("行 \(index) " + String(repeating: "x", count: 40)) }
        writer.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("t-") }.sorted()
        #expect(names.count == 3)
        #expect(names.contains { $0.hasSuffix(".1.log") })
        #expect(names.contains { $0.hasSuffix(".2.log") })
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int ?? 0
            #expect(size <= 1024 + 100)
        }
    }

    @Test("启动时清理超过保留天数的旧文件")
    func retention() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("t-20200101.log")
        FileManager.default.createFile(atPath: old.path, contents: Data("old".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: old.path)
        let writer = LogFileWriter(directory: dir, prefix: "t", retentionDays: 7)
        writer.append("新")
        writer.flush()
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
}
