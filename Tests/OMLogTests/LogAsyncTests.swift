// @author ixxxxoooo
// 日志后台化:环形缓冲、时间戳手写拼装、脱敏快路径、异步入队的顺序与可见性。

import Foundation
import Testing
@testable import OMLog

@Suite("日志后台化")
struct LogAsyncTests {
    private func entry(_ id: UInt64) -> LogEntry {
        LogEntry(id: id, date: Date(), level: .info, category: .app, message: "m\(id)", fields: [:], process: "app")
    }

    @Test("环形缓冲:满后覆盖最旧,按时间升序返回")
    func ringKeepsNewest() {
        var ring = LogRing(capacity: 3)
        for id in 1...5 { ring.append(entry(UInt64(id))) }
        #expect(ring.suffix(10).map(\.id) == [3, 4, 5])
        #expect(ring.suffix(2).map(\.id) == [4, 5])
        #expect(ring.suffix(0).isEmpty)
        var empty = LogRing(capacity: 3)
        #expect(empty.suffix(5).isEmpty)
        empty.append(entry(1))
        #expect(empty.suffix(5).map(\.id) == [1])
    }

    @Test("手写时间戳与 DateFormatter 输出一致")
    func timestampMatchesFormatter() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        for offset in stride(from: 0.0, to: 400 * 86_400.0, by: 7 * 86_400.0 + 12_345.678) {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            #expect(LogFormat.timestamp(date) == formatter.string(from: date), "\(LogFormat.timestamp(date)) vs \(formatter.string(from: date))")
            #expect(LogFormat.dayStamp(date) == day.string(from: date))
        }
    }

    @Test("脱敏快路径:无触发词原样返回,含密钥仍脱敏")
    func redactorFastPath() {
        let plain = "打开文件 /Users/x/project/main.swift 耗时 12ms"
        #expect(!LogRedactor.mayContainSecret(plain))
        #expect(LogRedactor.redact(plain) == plain)
        #expect(LogRedactor.mayContainSecret("Authorization: Basic abc"))
        #expect(LogRedactor.mayContainSecret("X_API_KEY=1"))
        #expect(!LogRedactor.redact("sk-ant-abcdefghij12345 与 Bearer abcdefgh12345").contains("abcdefghij"))
        #expect(LogRedactor.redact("MY_PASSWORD=hunter2").contains("‹已脱敏›"))
    }

    @Test("异步入队:recent 能读到此前全部日志且保持顺序")
    func recentDrainsQueue() {
        let system = LogSystem(level: .debug, osLog: false)
        for index in 0..<200 { system.log(index % 50 == 49 ? .error : .info, .app, "第 \(index) 条") }
        let messages = system.recent(limit: 500).map(\.message)
        #expect(messages == (0..<200).map { "第 \($0) 条" })
    }

    @Test("异步入队:消息在调用线程求值,脱敏在后台完成")
    func redactionHappensBeforeVisible() {
        let system = LogSystem(level: .info, osLog: false)
        system.log(.info, .app, "key sk-ant-abcdefghijk12345", fields: ["note": "TOKEN=abc123"])
        let recent = system.recent()
        #expect(recent.count == 1)
        #expect(!recent[0].line.contains("abcdefghijk"))
        #expect(!recent[0].line.contains("abc123"))
    }

    @Test("日志调用本身很快:1 万条 info 入队 < 300ms")
    func enqueueIsCheap() {
        let system = LogSystem(level: .info, osLog: false)
        let start = ContinuousClock.now
        for index in 0..<10_000 { system.log(.info, .perf, "事件 \(index)", fields: ["session": "s1"]) }
        let ms = OMLogger.milliseconds(since: start)
        #expect(ms < 300, "入队耗时 \(ms)ms")
        #expect(system.recent(limit: 3000).count == 2000)
    }
}
