// @author ixxxxoooo
// ACPKit StdioTransport 可靠性测试:向已关闭/子进程已退出的传输发送不得崩溃。

import Foundation
import Testing
@testable import ACPKit

@Suite("StdioTransport 可靠性")
struct StdioTransportTests {
    @Test("向已 stop 的传输发送不得崩溃,被优雅丢弃")
    func sendAfterStopIsSafe() async throws {
        let transport = StdioTransport(launch: ProcessLaunch(executable: "/bin/cat"))
        let events = try transport.start()
        let body = Data("hello, acp".utf8)
        transport.send(body)
        var got = false
        for await event in events {
            if case .line(let echoed) = event, echoed == body { got = true; break }
        }
        #expect(got)
        transport.stop()
        // 关闭后再发送两次:必须不抛 Objective-C 异常,不导致 abort。
        transport.send(body)
        transport.send(Data("再次发送".utf8))
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test("子进程退出后向传输发送不得崩溃,EPIPE 被优雅处理")
    func sendAfterProcessExitIsSafe() async throws {
        let transport = StdioTransport(launch: ProcessLaunch(executable: "/bin/sh", arguments: ["-c", "exit 0"]))
        let events = try transport.start()
        for await event in events {
            if case .closed = event { break }
        }
        transport.send(Data("进程已退出".utf8)) // 写入已无读端的管道,EPIPE 被优雅处理
        try await Task.sleep(for: .milliseconds(200))
    }
}
