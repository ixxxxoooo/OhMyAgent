// @author ixxxxoooo
// 进程树探针测试:用真实子进程验证后代与 shell 识别。

import Foundation
import Testing
@testable import OMLog

@Suite("ProcessTree")
struct ProcessTreeTests {
    @Test("本进程下运行着 shell 子进程时能识别,退出后不再识别")
    func detectsShellDescendant() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessTree.descendants(of: me).contains(process.processIdentifier))
        #expect(ProcessTree.hasShellDescendant(of: me))
        process.terminate()
        process.waitUntilExit()
        #expect(!ProcessTree.descendants(of: me).contains(process.processIdentifier))
    }

    @Test("非法 pid 没有后代")
    func invalidPid() {
        #expect(ProcessTree.descendants(of: 0).isEmpty)
        #expect(ProcessTree.descendants(of: -5).isEmpty)
        #expect(!ProcessTree.hasShellDescendant(of: 0))
    }
}
