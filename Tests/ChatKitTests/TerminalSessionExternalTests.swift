// @author ixxxxoooo
// 外部终端会话:输出追加与截断、UTF-8 边界、后台命令跟读输出文件并在结束时读尽。

import Foundation
import Testing
@testable import ChatKit

@MainActor
@Suite("外部终端会话")
struct TerminalSessionExternalTests {
    private func tempFile() -> String {
        NSTemporaryDirectory() + "oma-ext-term-\(UUID().uuidString).output"
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test("UTF-8 边界:末尾不完整的多字节字符留到下次")
    func utf8Boundary() {
        let bytes = Array("a你".utf8)  // 61 e4 bd a0
        #expect(TerminalSession.completeUTF8Length(Data(bytes)) == 4)
        #expect(TerminalSession.completeUTF8Length(Data(bytes.prefix(3))) == 1)
        #expect(TerminalSession.completeUTF8Length(Data(bytes.prefix(2))) == 1)
        #expect(TerminalSession.completeUTF8Length(Data(bytes.prefix(1))) == 1)
        #expect(TerminalSession.completeUTF8Length(Data()) == 0)
        #expect(TerminalSession.completeUTF8Length(Data(Array("😀".utf8).prefix(3))) == 0)
    }

    @Test("前台命令:整段输出替换,结束后记录退出码")
    func foreground() {
        let session = TerminalSession(id: "t", command: "", isExternal: true)
        session.updateCommand("ls")
        session.replaceExternal("a\nb\n")
        #expect(session.command == "ls" && session.output == "a\nb\n" && session.isRunning && !session.isBackground)
        session.finishExternal(exitCode: 0, signal: nil)
        #expect(!session.isRunning && session.exitCode == 0)
    }

    @Test("输出超过上限时丢弃头部并标记截断")
    func truncation() {
        let session = TerminalSession(id: "t", command: "x", isExternal: true)
        session.appendExternal(String(repeating: "a", count: TerminalSession.externalOutputLimit))
        session.appendExternal("TAIL")
        #expect(session.truncated && session.output.hasSuffix("TAIL") && session.output.count == TerminalSession.externalOutputLimit)
    }

    @Test("后台命令:跟读文件(含被拆开的汉字),结束时把剩余内容读完")
    func followsFile() async throws {
        let path = tempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bytes = Array("你好\n".utf8)
        FileManager.default.createFile(atPath: path, contents: Data(bytes.prefix(4)))  // 「你」完整 + 「好」的第一个字节
        let session = TerminalSession(id: "bg", command: "npm run dev", isExternal: true)
        session.followFile(path)
        #expect(session.isBackground)
        await wait { session.output.contains("你") }
        #expect(session.output == "你", "不完整的字节不能被解码成乱码")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes.dropFirst(4)))
        try handle.write(contentsOf: Data("ready\n".utf8))
        try handle.close()
        // 立刻结束:收尾必须把文件里剩余的内容读完,再标记结束
        session.finishExternal(exitCode: nil, signal: nil)
        await wait { !session.isRunning }
        #expect(!session.isRunning)
        #expect(session.output == "你好\nready\n")
    }

    @Test("非追加变化计数:追加不计,整段替换与截断计")
    func discontinuity() {
        let s = TerminalSession(id: "d", command: "x", isExternal: true)
        s.appendExternal("abc")
        #expect(s.discontinuity == 0)
        s.replaceExternal("xyz")
        #expect(s.discontinuity == 1 && s.output == "xyz")
        s.appendExternal(String(repeating: "a", count: TerminalSession.externalOutputLimit))
        #expect(s.discontinuity == 2 && s.truncated)
    }
}
